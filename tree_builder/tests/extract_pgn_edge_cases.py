#!/usr/bin/env python3
"""Scan PGN files for chesslib test edge cases. Outputs C-friendly snippets."""
import chess
import chess.pgn
import re
import sys
from pathlib import Path

PGN_PATHS = [
    Path(__file__).resolve().parents[2] / "pgn_databases/sicilian_kan/SicilianKan5Bd3.pgn",
    Path(__file__).resolve().parents[2] / "pgn_databases/sicilian_kan/SicilianKan5c4.pgn",
    Path(__file__).resolve().parents[2] / "pgn_databases/sicilian_kan/SicilianKan5Nc3.pgn",
    Path(__file__).resolve().parents[2] / "pgn_databases/sicilian_kan/SicilianKanOther5.pgn",
]
LICHESS_PGNS = Path(__file__).resolve().parents[2] / "lichess-opening-builder/pgns"

DISAMBIG_RE = re.compile(r"^[RNBQ][a-h1-8][a-h1-8]?[x]?[a-h][1-8]")
CASTLE_RE = re.compile(r"^O-O(-O)?$")
PROMO_RE = re.compile(r"=[QRBN]")
EP_SAN_RE = re.compile(r"^[a-h]x[a-h][36]$")  # exd6 style pawn capture to rank 3/6


def san_of(board, move):
    return board.san(move)


def scan_game(game, stats, max_games_per_file):
    board = game.board()
    moves_san = []
    event = game.headers.get("Event", "?")[:40]
    site = game.headers.get("Site", "?")[:20]

    for move in game.mainline_moves():
        fen_before = board.fen()
        san = san_of(board, move)
        uci = move.uci()
        ep_sq = board.ep_square
        clean = san.replace("+", "").replace("#", "")

        # Disambiguation (file/rank in SAN)
        if DISAMBIG_RE.match(clean):
            if clean not in stats["disambig"]:
                stats["disambig"][clean] = (fen_before, san, uci, event)

        # Castling
        if board.is_castling(move):
            tag = "O-O-O" if "O-O-O" in clean or clean == "O-O-O" else "O-O"
            if tag not in stats["castle"]:
                stats["castle"][tag] = (fen_before, san, uci, event)

        # Promotion
        if move.promotion:
            if clean not in stats["promo"]:
                stats["promo"][clean] = (fen_before, san, uci, event)

        # EP capture
        if board.is_en_passant(move):
            if len(stats.get("ep_list", [])) < 30:
                stats.setdefault("ep_list", []).append((fen_before, san, uci, event))

        # Non-pawn to EP square (the bug pattern)
        if ep_sq is not None and not board.is_en_passant(move):
            piece = board.piece_at(move.from_square)
            if piece and piece.piece_type != chess.PAWN and move.to_square == ep_sq:
                key = (fen_before, clean)
                if key not in stats["non_pawn_ep"]:
                    stats["non_pawn_ep"][key] = (fen_before, san, uci, event)

        board.push(move)
        moves_san.append(san)

    n_moves = len(moves_san)
    if n_moves >= 60 and len(stats["long_games"]) < 5:
        stats["long_games"].append((event, n_moves, " ".join(moves_san[:80]) + ("..." if n_moves > 80 else "")))
    if n_moves >= 50:
        stats["long_movetext"].append((event, site, n_moves, game))

    # Capture streak
    board2 = game.board()
    streak = 0
    max_streak = 0
    for m in game.mainline_moves():
        b2 = board2.copy()
        san = board2.san(m)
        is_cap = board2.is_capture(m)
        board2.push(m)
        if is_cap:
            streak += 1
            max_streak = max(max_streak, streak)
        else:
            streak = 0
    if max_streak >= 4 and len(stats["cap_streak"]) < 10:
        stats["cap_streak"].append((event, max_streak, n_moves))

    return n_moves


def main():
    stats = {
        "disambig": {},
        "castle": {},
        "promo": {},
        "non_pawn_ep": {},
        "ep_list": [],
        "long_games": [],
        "long_movetext": [],
        "cap_streak": [],
        "full_games": [],
    }

    paths = list(PGN_PATHS)
    if LICHESS_PGNS.exists():
        paths.extend(sorted(LICHESS_PGNS.glob("*.pgn"))[:5])

    MAX_GAMES = 2500
    games_seen = 0
    for pgn_path in paths:
        if not pgn_path.exists():
            print(f"skip missing {pgn_path}", file=sys.stderr)
            continue
        print(f"scanning {pgn_path.name}...", file=sys.stderr)
        file_games = 0
        with open(pgn_path) as f:
            while games_seen < MAX_GAMES and file_games < 600:
                game = chess.pgn.read_game(f)
                if game is None:
                    break
                n = scan_game(game, stats, 500)
                games_seen += 1
                file_games += 1
                if n >= 40 and len(stats["full_games"]) < 15:
                    mt = str(game.mainline_moves())
                    # rebuild movetext from game
                    board = game.board()
                    parts = []
                    move_no = 1
                    for m in game.mainline_moves():
                        san = board.san(m)
                        if board.turn == chess.WHITE:
                            parts.append(f"{move_no}.{san}")
                        else:
                            if move_no == 1 and len(parts) == 0:
                                parts.append(f"...{san}")
                            else:
                                parts.append(san)
                        board.push(m)
                        if board.turn == chess.WHITE:
                            move_no += 1
                    movetext = " ".join(parts)
                    if len(movetext) < 12000:
                        stats["full_games"].append((pgn_path.name, game.headers.get("Event", "?")[:50], n, movetext))

    print("\n=== DISAMBIGUATION (sample) ===")
    for i, (k, v) in enumerate(list(stats["disambig"].items())[:25]):
        fen, san, uci, ev = v
        print(f"  {san} -> {uci}")
        print(f'    FEN: {fen}')
        print(f'    // {ev}')

    print("\n=== CASTLING ===")
    for k, v in stats["castle"].items():
        fen, san, uci, ev = v
        print(f"  {k}: {san} ({uci})")

    print("\n=== PROMOTIONS (sample 15) ===")
    for i, (k, v) in enumerate(list(stats["promo"].items())[:15]):
        fen, san, uci, ev = v
        print(f"  {san} uci={uci}")

    print("\n=== NON-PAWN TO EP SQUARE ===")
    for k, v in stats["non_pawn_ep"].items():
        fen, san, uci, ev = v
        print(f"  {san} -> {uci}")
        print(f"    {fen}")

    print("\n=== EP CAPTURES ===")
    for v in stats["ep_list"][:10]:
        fen, san, uci, ev = v
        print(f"  {san} ({uci})")

    print("\n=== LONG GAMES ===")
    for ev, n, _ in stats["long_games"]:
        print(f"  {n} moves: {ev}")

    print("\n=== FULL GAME CANDIDATES ===")
    for fname, ev, n, mt in stats["full_games"][:12]:
        print(f"  {fname} | {n} plies | {ev}")
        print(f"    len={len(mt)}")

    # Output one long game movetext for embedding
    if stats["long_movetext"]:
        stats["long_movetext"].sort(key=lambda x: -x[2])
        g = stats["long_movetext"][0][3]
        board = g.board()
        parts = []
        mn = 1
        for m in g.mainline_moves():
            s = board.san(m)
            if board.turn == chess.WHITE:
                parts.append(f"{mn}.{s}")
            else:
                parts.append(s)
            board.push(m)
            if board.turn == chess.WHITE:
                mn += 1
        print(f"\nLONGEST: {stats['long_movetext'][0][2]} plies")
        print(" ".join(parts[:120]))


if __name__ == "__main__":
    main()
