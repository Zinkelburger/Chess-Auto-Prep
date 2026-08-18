"""Round 2: transfer with distance cap, shadow distance (soft transposition reach),
opponent-error column. Same tests as round 1."""
import atexit, sys
from harness import *
from experiment import (SKELETONS, TESTS, parse_skeleton, piece_diff, candidates,
                        move_eval, opp_replies, expectimax_lite, ELO)

import harness
atexit.register(lambda: harness._eng and harness._eng.quit())

XFER_CAP = 5     # max differing squares for a skeleton move to "transfer"
TOL = 40         # cp we'll give up vs chessdb best

def sound_moves(b, tol=TOL):
    d = chessdb(b.fen())
    if not d:
        return [x["uci"] for x in sf_multipv(b.fen(), 14, 4)]
    best = max(v["score"] for v in d.values())
    return [u for u, v in d.items() if v["score"] >= best - tol]

def min_dist(b, nodes):
    """Distance from position b (our turn) to nearest skeleton our-turn node."""
    return min(piece_diff(b, nb) for nb, _ in nodes)

def transfer(b, uci, nodes, cap=XFER_CAP):
    best = None
    for nb, u in nodes:
        if u != uci: continue
        d = piece_diff(b, nb)
        if d <= cap: best = d if best is None else min(best, d)
    return best

def shadow(b, uci, nodes, plies=4):
    """Expected (over Maia replies) minimum distance-to-skeleton we can maintain
    over the next `plies` plies, choosing among sound moves. Lower = the line
    'shadows' the skeleton even without transposing exactly."""
    b = b.copy(); b.push_uci(uci)
    def rec(bd, depth):  # bd: opponent to move
        tot = 0.0
        for u, pr in opp_replies(bd, mass=0.8, k=4):
            b2 = bd.copy(); b2.push_uci(u)   # our turn
            here = min_dist(b2, nodes)
            if depth <= 2:
                tot += pr * here
                continue
            best = None
            for ours in sound_moves(b2)[:4]:
                b3 = b2.copy(); b3.push_uci(ours)
                v = rec(b3, depth - 2)
                best = v if best is None else min(best, v)
            tot += pr * (min(here, best) if best is not None else here)
        return tot
    return rec(b, plies)

def run(skel_name, lines):
    nodes, goals, epds = parse_skeleton(lines)
    print(f"\n{'='*100}\nSKELETON: {skel_name}\n  " + "\n  ".join(lines))
    tally = {}
    for pos, expected in TESTS:
        b = fen_after(pos)
        cands = candidates(b, nodes)
        maia = maia_policy(b.fen(), ELO)
        d = chessdb(b.fen())
        best_cdb = max((v["score"] for v in d.values()), default=0)
        rows = []
        for u, srcs in cands.items():
            ev = move_eval(b, u)
            if best_cdb - ev > 120: continue  # don't waste lookahead on junk
            xf = transfer(b, u, nodes)
            sh = shadow(b, u, nodes)
            em = expectimax_lite(b, u)
            rows.append(dict(san=b.san(chess.Move.from_uci(u)), cdb=ev, loss=best_cdb - ev,
                             maia=maia.get(u, 0), xfer=xf, shadow=sh, em=em, err=em - ev))
        print(f"\n--- {pos}   (expected: {expected})")
        print(f"{'move':7}{'cdb':>6}{'loss':>6}{'maia%':>7}{'xfer':>6}{'shadow':>8}{'exmax':>7}{'oppErr':>8}")
        for r in sorted(rows, key=lambda r: -r["cdb"]):
            xf = "-" if r["xfer"] is None else str(r["xfer"])
            flag = " <==" if r["san"] == expected else ""
            print(f"{r['san']:7}{r['cdb']:>6}{r['loss']:>6}{100*r['maia']:>6.1f}%{xf:>6}{r['shadow']:>8.2f}{r['em']:>7.0f}{r['err']:>8.0f}{flag}")
        ok = [r for r in rows if r["loss"] <= TOL]
        picks = {
            "engine": max(rows, key=lambda r: r["cdb"])["san"],
            "exmax": max(ok, key=lambda r: r["em"])["san"],
            "xfer≤5": min(ok, key=lambda r: (999 if r["xfer"] is None else r["xfer"], -r["cdb"]))["san"],
            "shadow": min(ok, key=lambda r: (r["shadow"], -r["cdb"]))["san"],
            "shadow+xfer": min(ok, key=lambda r: (r["shadow"] - (2 if r["xfer"] is not None else 0), -r["cdb"]))["san"],
            "oppErr": max(ok, key=lambda r: r["err"])["san"],
        }
        for k, v in picks.items(): tally.setdefault(k, 0); tally[k] += (v == expected)
        print("  picks: " + "  |  ".join(f"{k}: {v}{'✓' if v == expected else '✗'}" for k, v in picks.items()))
        sys.stdout.flush()
    print(f"\nTALLY {skel_name}: " + ", ".join(f"{k}={v}/{len(TESTS)}" for k, v in tally.items()))

if __name__ == "__main__":
    for name, lines in SKELETONS.items():
        run(name, lines)
