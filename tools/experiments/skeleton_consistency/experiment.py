"""Given a Benko skeleton (Black), can different 'consistency' metrics rediscover
the moves the user expects at White's deviations?"""
import atexit, sys
from harness import *

import harness
atexit.register(lambda: harness._eng and harness._eng.quit())

ELO = 1800
SKELETONS = {
    "L2 only": ["1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6"],
    "L1+L2":   ["1.d4 Nf6 2.c4 c5 3.Nf3 cxd4 4.Nxd4 e5",
                "1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6"],
}
TESTS = [  # (position, expected move)
    ("1.d4 Nf6 2.Nf3", "c5"),
    ("1.d4 Nf6 2.Nf3 c5 3.d5", "b5"),
    ("1.d4 Nf6 2.Nf3 c5 3.c4", "cxd4"),
    ("1.d4 Nf6 2.Bf4", "c5"),
    ("1.d4 Nf6 2.Bf4 c5 3.e3", "Qb6"),
    ("1.d4 Nf6 2.e3", "c5"),
    ("1.d4 Nf6 2.c4 c5 3.Nf3 cxd4 4.Qxd4", "Nc6"),
]

# ─── skeleton parsing ───────────────────────────────────────────────────
def parse_skeleton(lines):
    """Returns (our_turn_nodes: list of (board_before, uci_move), goal_boards, all_epds)."""
    nodes, goals, epds = [], [], set()
    for line in lines:
        b = chess.Board(); import re
        for s in re.sub(r'\d+\.(\.\.)?', ' ', line).split():
            m = b.parse_san(s)
            if b.turn == chess.BLACK:
                nodes.append((b.copy(), m.uci()))
            b.push(m); epds.add(b.epd())
        goals.append(b.copy())
    return nodes, goals, epds

def piece_diff(a, b):
    """Number of squares whose contents differ."""
    pa, pb = a.piece_map(), b.piece_map()
    return sum(1 for sq in chess.SQUARES if pa.get(sq) != pb.get(sq))

def our_pawns(b, color=chess.BLACK):
    return set(b.pieces(chess.PAWN, color))

def jaccard(a, b):
    return len(a & b) / max(1, len(a | b))

# ─── candidate generation ───────────────────────────────────────────────
def candidates(b, nodes):
    """Union of engine multipv, chessdb top, Maia top, and skeleton-transfer moves."""
    cands = {}
    for x in sf_multipv(b.fen(), 20, 8):
        cands.setdefault(x["uci"], set()).add("sf")
    for u, v in list(chessdb(b.fen()).items())[:8]:
        cands.setdefault(u, set()).add("cdb")
    for u, p in list(maia_policy(b.fen(), ELO).items())[:6]:
        if p >= 0.03: cands.setdefault(u, set()).add("maia")
    for nb, u in nodes:
        m = chess.Move.from_uci(u)
        if m in b.legal_moves: cands.setdefault(u, set()).add("xfer")
    return cands

# ─── metrics ────────────────────────────────────────────────────────────
def eval_cp(b):
    """Side-to-move-POV cp from chessdb, falling back to Stockfish."""
    d = chessdb(b.fen())
    if d:
        return max(v["score"] for v in d.values())
    r = sf_multipv(b.fen(), 16, 1)
    if not r: return 0
    return r[0]["cp"] if b.turn == chess.WHITE else -r[0]["cp"]

def move_eval(b, uci):
    d = chessdb(b.fen())
    if uci in d: return d[uci]["score"]
    b2 = b.copy(); b2.push_uci(uci)
    return -eval_cp(b2)

def transfer_score(b, uci, nodes):
    """Smallest piece-diff to a skeleton node that played this move (lower=better)."""
    best = None
    for nb, u in nodes:
        if u != uci: continue
        d = piece_diff(b, nb)
        best = d if best is None else min(best, d)
    return best

def opp_replies(b, mass=0.85, k=5):
    p = maia_policy(b.fen(), ELO)
    out, acc = [], 0.0
    for u, pr in p.items():
        out.append((u, pr)); acc += pr
        if acc >= mass or len(out) >= k: break
    tot = sum(pr for _, pr in out)
    return [(u, pr / tot) for u, pr in out]

def our_choice(b, nodes, tol=40):
    """Cheap our-move policy for lookahead: transfer move if sound, else chessdb best."""
    d = chessdb(b.fen())
    best = max((v["score"] for v in d.values()), default=None) if d else None
    if best is None:
        r = sf_multipv(b.fen(), 14, 1); return r[0]["uci"] if r else None
    # black POV: chessdb score is from side to move? chessdb 'score' is from the side to move.
    for nb, u in sorted(nodes, key=lambda nu: piece_diff(b, nu[0])):
        m = chess.Move.from_uci(u)
        if m in b.legal_moves and u in d and d[u]["score"] >= best - tol:
            return u
    return max(d, key=lambda u: d[u]["score"])

def lookahead(b, uci, nodes, epds, goals, plies=4):
    """After our move, expand Maia replies and our cheap policy; return
    (exact-transposition mass, expected goal-pawn Jaccard, expected our-POV cp)."""
    b = b.copy(); b.push_uci(uci)
    if b.epd() in epds: return 1.0, 1.0, None
    def rec(bd, depth):
        if bd.epd() in epds: return 1.0, 1.0
        if depth == 0:
            return 0.0, max(jaccard(our_pawns(bd), our_pawns(g)) for g in goals)
        tm, tj = 0.0, 0.0
        for u, pr in opp_replies(bd):
            b2 = bd.copy(); b2.push_uci(u)
            if b2.epd() in epds: m, j = 1.0, 1.0
            else:
                ours = our_choice(b2, nodes)
                if ours is None: m, j = 0.0, 0.0
                else:
                    b3 = b2.copy(); b3.push_uci(ours)
                    m, j = rec(b3, depth - 2)
            tm += pr * m; tj += pr * j
        return tm, tj
    return (*rec(b, plies), None)

def expectimax_lite(b, uci):
    """Our-POV expected cp after Maia's reply (2 plies), using chessdb evals."""
    b2 = b.copy(); b2.push_uci(uci)
    tot = 0.0
    for u, pr in opp_replies(b2, mass=0.9, k=6):
        b3 = b2.copy(); b3.push_uci(u)
        # eval from side to move (us) = chessdb best score for us
        d = chessdb(b3.fen())
        e = max((v["score"] for v in d.values()), default=None) if d else None
        if e is None:
            r = sf_multipv(b3.fen(), 14, 1); e = (-r[0]["cp"] if r else 0)  # black POV
        tot += pr * e
    return tot

# ─── run ────────────────────────────────────────────────────────────────
def run(skel_name, lines):
    nodes, goals, epds = parse_skeleton(lines)
    print(f"\n{'='*100}\nSKELETON: {skel_name}\n  " + "\n  ".join(lines))
    for pos, expected in TESTS:
        b = fen_after(pos)
        cands = candidates(b, nodes)
        maia = maia_policy(b.fen(), ELO)
        d = chessdb(b.fen())
        best_cdb = max((v["score"] for v in d.values()), default=0)
        rows = []
        for u, srcs in cands.items():
            san = b.san(chess.Move.from_uci(u))
            ev = move_eval(b, u)  # side-to-move POV (black)
            xf = transfer_score(b, u, nodes)
            reach, struct, _ = lookahead(b, u, nodes, epds, goals)
            em = expectimax_lite(b, u)
            rows.append(dict(san=san, cdb=ev, loss=best_cdb - ev, maia=maia.get(u, 0),
                             xfer=xf, reach=reach, struct=struct, em=em, src=",".join(sorted(srcs))))
        print(f"\n--- {pos}   (expected: {expected})   Maia-W next: n/a")
        print(f"{'move':7}{'cdb':>6}{'loss':>6}{'maia%':>7}{'xfer':>6}{'reach':>7}{'struct':>8}{'exmax':>7}   sources")
        for r in sorted(rows, key=lambda r: -r["cdb"]):
            xf = "-" if r["xfer"] is None else str(r["xfer"])
            flag = " <==" if r["san"] == expected else ""
            print(f"{r['san']:7}{r['cdb']:>6}{r['loss']:>6}{100*r['maia']:>6.1f}%{xf:>6}{r['reach']:>7.2f}{r['struct']:>8.2f}{r['em']:>7.0f}   {r['src']}{flag}")
        # what each ranking picks (within 40cp of best)
        ok = [r for r in rows if r["loss"] <= 40]
        picks = {
            "engine-only": max(rows, key=lambda r: r["cdb"])["san"],
            "expectimax-lite(<=40)": max(ok, key=lambda r: r["em"])["san"],
            "transfer(<=40)": min(ok, key=lambda r: (999 if r["xfer"] is None else r["xfer"], -r["cdb"]))["san"],
            "reach(<=40)": max(ok, key=lambda r: (r["reach"], r["cdb"]))["san"],
            "struct(<=40)": max(ok, key=lambda r: (r["struct"], r["cdb"]))["san"],
            "reach+struct+xfer(<=40)": max(ok, key=lambda r: (r["reach"] + r["struct"] + (0.5 if r["xfer"] is not None and r["xfer"] <= 3 else 0), r["cdb"]))["san"],
        }
        print("  picks: " + "  |  ".join(f"{k}: {v}{'✓' if v == expected else '✗'}" for k, v in picks.items()))
        sys.stdout.flush()

if __name__ == "__main__":
    for name, lines in SKELETONS.items():
        run(name, lines)
