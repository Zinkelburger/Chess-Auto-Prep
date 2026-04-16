#!/usr/bin/env python3
"""
Explore "robust move" idea: find our moves that score well
across multiple opponent responses from a given position.
"""
import chess
import chess.engine
import requests
import time
import sys
from collections import defaultdict

LICHESS_URL = "https://explorer.lichess.ovh/lichess"
STOCKFISH = "/usr/bin/stockfish"
MULTIPV = 8
DEPTH = 20

import os
LICHESS_TOKEN = os.environ.get("LICHESS_TOKEN", "")

def lichess_moves(fen, ratings="2000,2200,2500", speeds="blitz,rapid,classical"):
    """Query Lichess explorer and return list of (san, uci, games, prob)."""
    headers = {}
    if LICHESS_TOKEN:
        headers["Authorization"] = f"Bearer {LICHESS_TOKEN}"
    resp = requests.get(LICHESS_URL, params={
        "variant": "standard",
        "speeds": speeds,
        "ratings": ratings,
        "fen": fen,
    }, headers=headers, timeout=15)
    resp.raise_for_status()
    data = resp.json()

    total = data.get("white", 0) + data.get("draws", 0) + data.get("black", 0)
    moves = []
    for m in data.get("moves", []):
        g = m.get("white", 0) + m.get("draws", 0) + m.get("black", 0)
        prob = g / total if total else 0
        moves.append({
            "san": m["san"],
            "uci": m["uci"],
            "games": g,
            "prob": prob,
            "white_wr": m.get("white", 0) / g if g else 0,
            "draw_r": m.get("draws", 0) / g if g else 0,
            "black_wr": m.get("black", 0) / g if g else 0,
        })
    return moves, total


def stockfish_top_moves(engine, fen, multipv=MULTIPV, depth=DEPTH):
    """Return list of (uci, san, cp_eval) for top N moves."""
    board = chess.Board(fen)
    info_list = engine.analyse(board, chess.engine.Limit(depth=depth), multipv=multipv)
    results = []
    for info in info_list:
        pv = info.get("pv", [])
        if not pv:
            continue
        move = pv[0]
        score = info["score"].white()
        if score.is_mate():
            cp = 10000 * (1 if score.mate() > 0 else -1)
        else:
            cp = score.score()
        results.append({
            "uci": move.uci(),
            "san": board.san(move),
            "cp": cp,
        })
    return results


def apply_move_fen(fen, uci_str):
    board = chess.Board(fen)
    move = chess.Move.from_uci(uci_str)
    board.push(move)
    return board.fen()


def explore_position(fen, we_are_white, label=""):
    """
    Given a position where it's the opponent's turn:
    1. Get opponent candidate moves from Lichess
    2. For each, apply the move, then Stockfish our top responses
    3. Cross-reference to find robust moves
    """
    board = chess.Board(fen)
    opp_to_move = board.turn  # opponent is on move

    print(f"\n{'='*70}")
    if label:
        print(f"  {label}")
    print(f"  FEN: {fen}")
    print(f"  Side to move: {'White' if opp_to_move == chess.WHITE else 'Black'} (opponent)")
    print(f"  We are: {'White' if we_are_white else 'Black'}")
    print(f"{'='*70}")

    opp_moves, total_games = lichess_moves(fen)
    if not opp_moves:
        print("  No moves in Lichess DB for this position.")
        return

    print(f"\n  Opponent has {len(opp_moves)} candidate moves ({total_games:,} total games):\n")
    for m in opp_moves[:10]:
        print(f"    {m['san']:8s}  {m['games']:6d} games  ({m['prob']*100:5.1f}%)  "
              f"W:{m['white_wr']*100:.0f}% D:{m['draw_r']*100:.0f}% B:{m['black_wr']*100:.0f}%")

    # Rate-limit
    time.sleep(1.5)

    # For each opponent move, get our best responses
    engine = chess.engine.SimpleEngine.popen_uci(STOCKFISH)
    engine.configure({"Threads": 4, "Hash": 256})

    # move_san -> list of {opp_move, cp, rank, opp_prob}
    our_move_scores = defaultdict(list)

    significant_opp_moves = [m for m in opp_moves if m["prob"] >= 0.02]
    if len(significant_opp_moves) < 2:
        significant_opp_moves = opp_moves[:4]

    print(f"\n  Analysing our responses to {len(significant_opp_moves)} opponent moves (depth {DEPTH})...\n")

    for opp in significant_opp_moves:
        new_fen = apply_move_fen(fen, opp["uci"])
        our_top = stockfish_top_moves(engine, new_fen, multipv=MULTIPV, depth=DEPTH)

        print(f"  After {opp['san']} ({opp['prob']*100:.1f}%):")
        for i, mv in enumerate(our_top[:5]):
            eval_str = f"{mv['cp']:+d}cp" if abs(mv['cp']) < 9999 else ("M" if mv['cp'] > 0 else "-M")
            print(f"      {i+1}. {mv['san']:8s} {eval_str}")
            our_move_scores[mv["san"]].append({
                "opp_move": opp["san"],
                "opp_prob": opp["prob"],
                "cp": mv["cp"],
                "rank": i + 1,
            })
        print()

    engine.quit()

    # Now find robust moves
    print(f"\n  {'='*60}")
    print(f"  ROBUSTNESS ANALYSIS")
    print(f"  {'='*60}")
    print(f"  Moves that appear as good responses to multiple opponent moves:\n")

    sign = 1 if we_are_white else -1

    scored = []
    for san, appearances in our_move_scores.items():
        n_covers = len(appearances)
        if n_covers < 2:
            continue

        # Weighted average eval (by opponent probability)
        total_weight = sum(a["opp_prob"] for a in appearances)
        if total_weight == 0:
            continue
        weighted_eval = sum(a["cp"] * a["opp_prob"] for a in appearances) / total_weight
        avg_rank = sum(a["rank"] for a in appearances) / n_covers

        # "Coverage" = sum of opponent probability this move covers
        coverage = sum(a["opp_prob"] for a in appearances)

        # Worst eval across appearances (from our perspective)
        worst_eval = min(a["cp"] * sign for a in appearances) * sign

        scored.append({
            "san": san,
            "covers": n_covers,
            "coverage": coverage,
            "weighted_eval": weighted_eval,
            "worst_eval": worst_eval,
            "avg_rank": avg_rank,
            "appearances": appearances,
        })

    # Sort by coverage * weighted_eval quality
    scored.sort(key=lambda x: (x["covers"], x["coverage"], x["weighted_eval"] * sign), reverse=True)

    if not scored:
        print("  No move appears across multiple opponent lines.")
    else:
        for s in scored[:15]:
            eval_from_our_side = s["weighted_eval"] * sign
            worst_from_our_side = s["worst_eval"] * sign
            covers_str = ", ".join(f"{a['opp_move']}({a['cp']:+d})" for a in s["appearances"])
            print(f"  {s['san']:8s}  covers {s['covers']}/{len(significant_opp_moves)} opp moves  "
                  f"coverage={s['coverage']*100:.0f}%  "
                  f"avg_eval={s['weighted_eval']:+.0f}cp  "
                  f"worst={s['worst_eval']:+d}cp  "
                  f"avg_rank={s['avg_rank']:.1f}")
            print(f"             {covers_str}")

    # Highlight the best robust move
    if scored:
        best = scored[0]
        print(f"\n  >>> MOST ROBUST: {best['san']} — works against "
              f"{best['covers']}/{len(significant_opp_moves)} opponent moves, "
              f"covering {best['coverage']*100:.0f}% of games, "
              f"avg eval {best['weighted_eval']:+.0f}cp")


def explore_our_turn(fen, we_are_white, label=""):
    """
    Given a position where it's OUR turn, find which of our moves
    are robust against opponent's likely responses.

    1. Stockfish gives us candidate moves
    2. For each of our candidates, apply it, query Lichess for opponent responses
    3. For each opponent response, eval the resulting position
    4. A "robust" move is one where the eval stays good no matter what opponent plays
    """
    board = chess.Board(fen)

    print(f"\n{'='*70}")
    if label:
        print(f"  {label}")
    print(f"  FEN: {fen}")
    print(f"  Side to move: {'White' if board.turn == chess.WHITE else 'Black'} (US)")
    print(f"  We are: {'White' if we_are_white else 'Black'}")
    print(f"{'='*70}")

    engine = chess.engine.SimpleEngine.popen_uci(STOCKFISH)
    engine.configure({"Threads": 4, "Hash": 256})

    # Get our top candidate moves
    our_candidates = stockfish_top_moves(engine, fen, multipv=6, depth=DEPTH)

    print(f"\n  Our {len(our_candidates)} candidate moves:\n")
    for i, mv in enumerate(our_candidates):
        eval_str = f"{mv['cp']:+d}cp"
        print(f"    {i+1}. {mv['san']:8s} {eval_str}")

    sign = 1 if we_are_white else -1

    # For each of our candidates, check robustness against opponent responses
    print(f"\n  Checking each candidate against opponent's Lichess responses...\n")

    results = []

    for cand in our_candidates[:5]:
        new_fen = apply_move_fen(fen, cand["uci"])
        time.sleep(1.5)
        opp_moves, total_games = lichess_moves(new_fen)

        if not opp_moves:
            print(f"  {cand['san']}: No Lichess data after this move")
            continue

        significant = [m for m in opp_moves if m["prob"] >= 0.03]
        if len(significant) < 2:
            significant = opp_moves[:3]

        print(f"  After our {cand['san']} ({cand['cp']:+d}cp), opponent has {len(opp_moves)} moves "
              f"({total_games:,} games):")

        evals_after = []
        for opp in significant:
            pos_after_opp = apply_move_fen(new_fen, opp["uci"])
            info = engine.analyse(chess.Board(pos_after_opp), chess.engine.Limit(depth=DEPTH))
            sc = info["score"].white()
            cp = 10000 * (1 if sc.mate() > 0 else -1) if sc.is_mate() else sc.score()
            evals_after.append({"opp_san": opp["san"], "opp_prob": opp["prob"], "cp": cp})
            eval_str = f"{cp:+d}cp"
            print(f"      vs {opp['san']:8s} ({opp['prob']*100:.0f}%): {eval_str}")

        # Compute robustness: worst-case eval weighted by probability
        if evals_after:
            worst_cp = min(e["cp"] * sign for e in evals_after) * sign
            avg_cp = sum(e["cp"] * e["opp_prob"] for e in evals_after) / sum(e["opp_prob"] for e in evals_after)
            spread = max(e["cp"] for e in evals_after) - min(e["cp"] for e in evals_after)

            results.append({
                "san": cand["san"],
                "initial_cp": cand["cp"],
                "worst_cp": worst_cp,
                "avg_cp": avg_cp,
                "spread": spread,
                "n_opp": len(significant),
            })
            print(f"      → worst={worst_cp:+d}  avg={avg_cp:+.0f}  spread={spread}cp")
        print()

    engine.quit()

    if results:
        print(f"\n  {'='*60}")
        print(f"  ROBUSTNESS RANKING (lower spread = more robust)")
        print(f"  {'='*60}\n")

        results.sort(key=lambda r: r["spread"])
        for i, r in enumerate(results):
            print(f"    {i+1}. {r['san']:8s}  initial={r['initial_cp']:+d}  "
                  f"worst={r['worst_cp']:+d}  avg={r['avg_cp']:+.0f}  "
                  f"spread={r['spread']}cp  vs {r['n_opp']} opp moves")

        # Best by spread
        best = results[0]
        print(f"\n  >>> MOST ROBUST: {best['san']} — spread only {best['spread']}cp "
              f"across {best['n_opp']} opponent responses, worst case {best['worst_cp']:+d}cp")

        # But also show best by worst-case
        best_worst = max(results, key=lambda r: r["worst_cp"] * sign)
        if best_worst["san"] != best["san"]:
            print(f"  >>> BEST WORST-CASE: {best_worst['san']} — "
                  f"worst case {best_worst['worst_cp']:+d}cp")


if __name__ == "__main__":
    # FEN 1: Black to move — opponent has several candidate moves,
    # we (White) want robust responses
    fen1 = "rn2k1nr/1p3ppp/1q2p3/3pP3/8/1pPQ1N2/P4RPP/RNB2K2 b kq - 1 13"

    # FEN 2: White to move — we ARE white, checking which of our moves
    # stays good regardless of black's response
    fen2 = "rn2kbnr/pp3ppp/2q1p3/3pP3/PPb5/2P1BN2/2B2PPP/RN1QK2R w KQkq - 1 12"

    print("\n" + "█" * 70)
    print("  ROBUST MOVE EXPLORER")
    print("█" * 70)

    # FEN1: it's opponent's (black's) turn, we are white
    # Ask: after each black move, what white move is good across all of them?
    explore_position(fen1, we_are_white=True,
                     label="Position 1: Black to move, White wants robust reply")

    print("\n\n")

    # FEN2: it's our (white's) turn
    # Ask: which of our moves stays robust no matter what black plays?
    explore_our_turn(fen2, we_are_white=True,
                     label="Position 2: White to move, checking robustness against black responses")
