"""Experiment harness: Maia policy, Stockfish MultiPV, chessdb evals, caches."""
import json, os, sqlite3, time, urllib.request, urllib.parse
import numpy as np
import chess, chess.engine
import onnxruntime as ort

ROOT = "/home/anbernal/Projects/Chess-Auto-Prep"
HERE = os.path.dirname(os.path.abspath(__file__))
SF = os.path.expanduser("~/.local/share/com.example.chess_auto_prep/stockfish-linux")

# ─── cache ──────────────────────────────────────────────────────────────
_db = sqlite3.connect(os.path.join(HERE, "cache.db"))
_db.execute("create table if not exists kv (k text primary key, v text)")
def _get(k):
    r = _db.execute("select v from kv where k=?", (k,)).fetchone()
    return json.loads(r[0]) if r else None
def _put(k, v):
    _db.execute("insert or replace into kv values (?,?)", (k, json.dumps(v))); _db.commit()

# ─── Maia ───────────────────────────────────────────────────────────────
_vocab = json.load(open(f"{ROOT}/assets/data/all_moves_maia3_reversed.json"))
if isinstance(_vocab, dict):  # index->uci or uci->index?
    items = sorted(_vocab.items(), key=lambda kv: int(kv[0]) if str(kv[0]).isdigit() else int(kv[1]))
    if str(items[0][0]).isdigit():
        _vocab = [v for _, v in items]
    else:
        _vocab = [k for k, _ in sorted(_vocab.items(), key=lambda kv: kv[1])]
_vidx = {u: i for i, u in enumerate(_vocab)}
_so = ort.SessionOptions(); _so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
_sess = ort.InferenceSession(f"{ROOT}/assets/maia3_simplified.onnx", _so, providers=["CPUExecutionProvider"])
PIECES = "PNBRQKpnbrqk"

def maia_policy(fen, elo=1800):
    key = f"maia|{elo}|{fen}"
    c = _get(key)
    if c: return c
    b = chess.Board(fen)
    is_black = b.turn == chess.BLACK
    if is_black:
        b = b.mirror()  # flips vertically & swaps colours, same as mirror_fen
    t = np.zeros((1, 64, 12), dtype=np.float32)
    for sq, pc in b.piece_map().items():
        t[0, sq, PIECES.index(pc.symbol())] = 1.0
    mask = np.full(len(_vocab), -np.inf, dtype=np.float32)
    legal = {}
    for m in b.legal_moves:
        u = m.uci()
        if u in _vidx:
            legal[u] = _vidx[u]; mask[_vidx[u]] = 0.0
    out = _sess.run(["logits_move", "logits_value"], {
        "tokens": t, "elo_self": np.array([elo], np.float32), "elo_oppo": np.array([elo], np.float32)})
    logits = out[0][0] + mask
    logits -= logits.max()
    p = np.exp(logits); p /= p.sum()
    res = {}
    for u, i in legal.items():
        uu = u
        if is_black:
            uu = u[0] + str(9 - int(u[1])) + u[2] + str(9 - int(u[3])) + u[4:]
        res[uu] = float(p[i])
    res = dict(sorted(res.items(), key=lambda kv: -kv[1]))
    _put(key, res)
    return res

# ─── chessdb ────────────────────────────────────────────────────────────
def chessdb(fen):
    """Every move chessdb.cn knows from `fen`, or {} if it knows none.

    urlopen raises on any non-200, so a server that refused to answer and a
    position chessdb genuinely does not know arrive looking identical -- and
    caching the refusal would record "chessdb knows nothing here"
    permanently.  So: back off and retry, and only ever cache an answer the
    server actually gave.
    """
    key = f"cdb|{fen}"
    c = _get(key)
    if c is not None: return c
    url = "https://www.chessdb.cn/cdb.php?action=queryall&json=1&board=" + urllib.parse.quote(fen)
    d = None
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                d = json.load(r)
            break
        except Exception:
            time.sleep(min(2 ** attempt, 30))
    if d is None:
        # Never reached the server. Uncached, so a later call can try again.
        return {}
    moves = {}
    if d.get("status") == "ok":
        for m in d["moves"]:
            moves[m["uci"]] = {"score": m["score"], "san": m["san"], "rank": m.get("rank"), "note": m.get("note")}
    _put(key, moves)
    time.sleep(0.15)
    return moves

# ─── Stockfish ──────────────────────────────────────────────────────────
_eng = None
def engine():
    global _eng
    if _eng is None:
        _eng = chess.engine.SimpleEngine.popen_uci(SF)
        _eng.configure({"Threads": 8, "Hash": 1024})
    return _eng

def sf_multipv(fen, depth=20, multipv=6):
    key = f"sf|{depth}|{multipv}|{fen}"
    c = _get(key)
    if c: return c
    b = chess.Board(fen)
    info = engine().analyse(b, chess.engine.Limit(depth=depth), multipv=multipv)
    res = []
    for i in info:
        if "pv" not in i: continue
        sc = i["score"].white()
        cp = sc.score(mate_score=10000)
        res.append({"uci": i["pv"][0].uci(), "san": b.san(i["pv"][0]), "cp": cp,
                    "pv": [m.uci() for m in i["pv"][:8]]})
    _put(key, res)
    return res

def san_line(fen, ucis):
    b = chess.Board(fen); out = []
    for u in ucis:
        m = chess.Move.from_uci(u); out.append(b.san(m)); b.push(m)
    return " ".join(out)

def fen_after(moves_san, start=chess.STARTING_FEN):
    b = chess.Board(start)
    import re
    for s in re.sub(r'\d+\.(\.\.)?', ' ', moves_san).split():
        b.push_san(s)
    return b

def epd(b): return b.epd()  # no move counters
