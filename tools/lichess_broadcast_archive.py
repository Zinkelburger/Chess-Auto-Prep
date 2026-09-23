#!/usr/bin/env python3
"""Every official Lichess broadcast since 2020, minus what we already have.

Lichess publishes each month's official (tiered) broadcast games at
`database.lichess.org/broadcast/` — about 1.2 million games, a few hundred
MB compressed. TWIC carries many of the same events, so a lookup that
counted both would count one game twice. This tool keeps only what TWIC and
the curated collections under `Documents/lichess_broadcasts/` do not have,
as the collection `lichess-official`:

    python3 tools/lichess_broadcast_archive.py fetch            # download new months
    python3 tools/lichess_broadcast_archive.py build            # filter, then import
    python3 tools/lichess_broadcast_archive.py status

`build` writes `months/<YYYY-MM>.pgn` (comments stripped) and a manifest,
then builds `lichess-official.db` with the app's importer
(`tools/master_import_pgn.dart`), which the chess-prep MCP searches beside
TWIC. Community broadcasts are not in the downloads; collect those with
`tools/lichess_broadcasts.py by <owner> --community-only`.

A game is dropped when:
* it is not standard chess (`Variant` other than Standard, or a `FEN`);
* either side is an engine (`BOT` title — TCEC and friends);
* it has no moves;
* the same moves and result already exist in TWIC, another collection or an
  earlier month with a player sharing a name part — broadcasters and TWIC
  write `Zhou Jianchao`, `Zhou, Jianchao` and `Shmeliov,D` for one person,
  and dates differ (the downloads only carry `UTCDate`).

Needs the `zstd` command. Downloads are cached under
`~/.cache/chess-prep/lichess-broadcast-db/` and never fetched twice.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.request
import zlib
from pathlib import Path
from typing import Iterable, Iterator

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lichess_broadcasts import collection_dir, event_name  # noqa: E402

LIST_URL = "https://database.lichess.org/broadcast/list.txt"
COLLECTION = "lichess-official"
USER_AGENT = "chess-auto-prep/1.0 (+https://chessautoprep.com)"
_MONTH = re.compile(r"lichess_db_broadcast_(\d{4}-\d{2})\.pgn\.zst$")

#: Tags carried into the kept PGN; the rest (Opening, StudyName, clocks in
#: comments) only cost space. The importer reads the first dozen.
KEEP_TAGS = (
    "Event", "Site", "Date", "Round", "White", "Black", "Result",
    "WhiteElo", "BlackElo", "WhiteTitle", "BlackTitle", "WhiteFideId",
    "BlackFideId", "ECO", "TimeControl", "BroadcastName", "BroadcastURL",
    "GameURL",
)

_TAG = re.compile(r'^\[(\w+)\s+"(.*)"\]\s*$')
_COMMENT = re.compile(r"\{[^}]*\}")
_VARIATION = re.compile(r"\([^()]*\)")
_MOVE_NO = re.compile(r"^\d+\.+$")
_RESULTS = {"1-0", "0-1", "1/2-1/2", "*"}


def cache_dir() -> Path:
    override = os.environ.get("CHESS_PREP_BROADCAST_CACHE")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".cache" / "chess-prep" / "lichess-broadcast-db"


# ── Moves and identity ─────────────────────────────────────────────────────


def sans(movetext: str) -> list[str]:
    """SAN tokens of the main line, comments, variations, numbers and NAGs gone."""
    body = _COMMENT.sub(" ", movetext)
    while True:
        stripped = _VARIATION.sub(" ", body)
        if stripped == body:
            break
        body = stripped
    out = []
    for tok in body.split():
        if _MOVE_NO.match(tok) or tok in _RESULTS or tok.startswith("$"):
            continue
        tok = re.sub(r"^\d+\.+", "", tok).rstrip("!?")
        if tok:
            out.append(tok)
    return out


def name_parts(name: str) -> set[str]:
    """Lower-case name parts of two or more letters (initials say little)."""
    return {t for t in re.findall(r"[a-z]+", name.lower()) if len(t) > 1}


def moves_digest(moves: list[str], result: str) -> bytes:
    return hashlib.blake2b((result + " " + " ".join(moves)).encode(), digest_size=8).digest()


class Seen:
    """Games already held somewhere, as (moves + result, white name part)."""

    def __init__(self) -> None:
        self._keys: set[bytes] = set()

    @staticmethod
    def _key(digest: bytes, part: str) -> bytes:
        return hashlib.blake2b(digest + part.encode(), digest_size=8).digest()

    def add(self, moves: list[str], result: str, white: str) -> None:
        digest = moves_digest(moves, result)
        for part in name_parts(white) or {"?"}:
            self._keys.add(self._key(digest, part))

    def has(self, moves: list[str], result: str, white: str) -> bool:
        digest = moves_digest(moves, result)
        return any(self._key(digest, p) in self._keys for p in name_parts(white) or {"?"})

    def __len__(self) -> int:
        return len(self._keys)


def seed_from_db(seen: Seen, path: Path) -> int:
    """Add every game of a master-format database (TWIC or a collection)."""
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        try:
            row = conn.execute("SELECT value FROM meta WHERE key = 'movetext_dict'").fetchone()
            zdict = bytes(row[0]) if row and row[0] else None
        except sqlite3.OperationalError:
            zdict = None
        n = 0
        for white, result, raw in conn.execute("SELECT white, result, movetext FROM games"):
            if raw is None:
                continue
            if isinstance(raw, str):
                text = raw
            else:
                d = zlib.decompressobj(zdict=zdict) if zdict else zlib.decompressobj()
                text = (d.decompress(bytes(raw)) + d.flush()).decode("utf-8", "replace")
            seen.add(sans(text), result, white)
            n += 1
        return n
    finally:
        conn.close()


# ── Reading a month ────────────────────────────────────────────────────────


def games_in(lines: Iterable[str]) -> Iterator[tuple[dict[str, str], str]]:
    """(tags, movetext) per game from a PGN line stream."""
    tags: dict[str, str] = {}
    body: list[str] = []
    for line in lines:
        line = line.rstrip("\n")
        m = _TAG.match(line)
        if m:
            if body:
                yield tags, " ".join(body)
                tags, body = {}, []
            tags[m.group(1)] = m.group(2)
        elif line.strip():
            body.append(line.strip())
    if tags or body:
        yield tags, " ".join(body)


def keep_reason(tags: dict[str, str], moves: list[str]) -> str | None:
    """Why a game is dropped before de-duplication, or None to keep it."""
    variant = tags.get("Variant", "Standard").strip().lower()
    if variant not in ("standard", "") or tags.get("FEN"):
        return "variant"
    if "BOT" in (tags.get("WhiteTitle", "").upper(), tags.get("BlackTitle", "").upper()):
        return "engine"
    if not moves:
        return "no_moves"
    return None


def render(tags: dict[str, str], moves: list[str], result: str) -> str:
    out = dict(tags)
    if not out.get("Date") or "?" in out.get("Date", "?"):
        out["Date"] = tags.get("UTCDate") or out.get("Date") or "????.??.??"
    if tags.get("BroadcastName"):
        # "Round 2: A - B" names the pairing, not the event.
        out["Event"] = event_name(tags.get("Event", ""), tags["BroadcastName"])
    site = out.get("Site", "")
    if not site or site.startswith(("http://", "https://")):
        out["Site"] = "?"
    head = "\n".join(f'[{k} "{out[k]}"]' for k in KEEP_TAGS if out.get(k))
    numbered = []
    for i, san in enumerate(moves):
        if i % 2 == 0:
            numbered.append(f"{i // 2 + 1}. {san}")
        else:
            numbered.append(san)
    return f"{head}\n\n{' '.join(numbered)} {result}\n\n"


def filter_month(zst: Path, out: Path, seen: Seen) -> dict[str, int]:
    """Write the month's new games to [out]; counts by fate."""
    counts = {"read": 0, "kept": 0, "variant": 0, "engine": 0, "no_moves": 0, "duplicate": 0}
    proc = subprocess.Popen(
        ["zstd", "-dcq", str(zst)], stdout=subprocess.PIPE, text=True, encoding="utf-8",
        errors="replace",
    )
    tmp = out.with_suffix(".pgn.tmp")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tmp.open("w", encoding="utf-8") as f:
            assert proc.stdout is not None
            for tags, movetext in games_in(proc.stdout):
                counts["read"] += 1
                moves = sans(movetext)
                reason = keep_reason(tags, moves)
                if reason:
                    counts[reason] += 1
                    continue
                result = tags.get("Result", "*")
                white = tags.get("White", "")
                if seen.has(moves, result, white):
                    counts["duplicate"] += 1
                    continue
                seen.add(moves, result, white)
                f.write(render(tags, moves, result))
                counts["kept"] += 1
    finally:
        if proc.stdout is not None:
            proc.stdout.close()
        rc = proc.wait()
    if rc != 0:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"zstd failed on {zst} (exit {rc})")
    os.replace(tmp, out)
    return counts


# ── Commands ───────────────────────────────────────────────────────────────


def month_of(path_or_url: str) -> str | None:
    m = _MONTH.search(path_or_url)
    return m.group(1) if m else None


def fetch(months_from: str, months_to: str | None) -> list[Path]:
    cache = cache_dir()
    cache.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(LIST_URL, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as r:
        urls = [u.strip() for u in r.read().decode().splitlines() if u.strip()]
    got = []
    for url in sorted(urls):
        month = month_of(url)
        if not month or month < months_from or (months_to and month > months_to):
            continue
        dest = cache / Path(url).name
        if not dest.exists():
            print(f"downloading {month}", file=sys.stderr)
            part = dest.with_suffix(".part")
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=600) as r, part.open("wb") as f:
                while chunk := r.read(1 << 20):
                    f.write(chunk)
            os.replace(part, dest)
            time.sleep(1)
        got.append(dest)
    return got


def other_databases(root: Path, twic: Path | None) -> list[Path]:
    out = [twic] if twic and twic.exists() else []
    for db in sorted(root.parent.glob("*/*.db")):
        if db.parent != root and db.stem == db.parent.name:
            out.append(db)
    return out


def twic_path() -> Path:
    override = os.environ.get("CHESS_PREP_MASTER_DB")
    if override:
        return Path(override).expanduser()
    base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return base / "com.example.chess_auto_prep" / "master_games.db"


def build(root: Path, zsts: list[Path], import_db: bool) -> dict:
    seen = Seen()
    sources = {}
    for db in other_databases(root, twic_path()):
        started = time.monotonic()
        n = seed_from_db(seen, db)
        sources[str(db)] = n
        print(f"known games: {n} from {db} ({time.monotonic() - started:.0f}s)", file=sys.stderr)
    manifest = {"collection": COLLECTION, "dedupe_against": sources, "months": {}}
    months_dir = root / "months"
    for zst in sorted(zsts, key=lambda p: p.name):
        month = month_of(zst.name)
        if not month:
            continue
        counts = filter_month(zst, months_dir / f"{month}.pgn", seen)
        manifest["months"][month] = counts
        print(f"{month}: {counts}", file=sys.stderr)
    totals = {k: sum(m[k] for m in manifest["months"].values()) for k in
              ("read", "kept", "variant", "engine", "no_moves", "duplicate")}
    manifest["totals"] = totals
    manifest["built_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    root.mkdir(parents=True, exist_ok=True)
    (root / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n", encoding="utf-8")
    if import_db:
        import_months(root)
    return manifest


def import_months(root: Path) -> None:
    """Rebuild `<collection>.db` from the month files with the app's importer."""
    db = root / f"{COLLECTION}.db"
    for suffix in ("", "-wal", "-shm"):
        Path(f"{db}{suffix}").unlink(missing_ok=True)
    files = sorted(str(p) for p in (root / "months").glob("*.pgn"))
    repo = Path(__file__).resolve().parent.parent
    env = dict(os.environ, MASTER_IMPORT_ARGS=" ".join([str(db), *files]))
    subprocess.run(
        [str(repo / "scripts" / "ci.sh"), "test", "tools/master_import_pgn.dart"],
        cwd=repo, env=env, check=True,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", help="collection directory (default Documents/lichess_broadcasts/lichess-official)")
    sub = parser.add_subparsers(dest="command", required=True)
    p_fetch = sub.add_parser("fetch", help="download months not yet cached")
    p_build = sub.add_parser("build", help="filter cached months and build the database")
    for p in (p_fetch, p_build):
        p.add_argument("--from", dest="months_from", default="2020-01", help="first month YYYY-MM")
        p.add_argument("--to", dest="months_to", help="last month YYYY-MM")
    p_build.add_argument("--no-import", action="store_true", help="write month files only")
    sub.add_parser("status", help="print the manifest totals")
    args = parser.parse_args(argv)
    root = collection_dir(COLLECTION, args.out)

    if args.command == "fetch":
        got = fetch(args.months_from, args.months_to)
        print(f"{len(got)} months cached in {cache_dir()}")
        return 0
    if args.command == "build":
        zsts = [
            p for p in cache_dir().glob("*.pgn.zst")
            if (m := month_of(p.name)) and m >= args.months_from
            and (not args.months_to or m <= args.months_to)
        ]
        if not zsts:
            print("nothing cached; run fetch first", file=sys.stderr)
            return 1
        manifest = build(root, zsts, import_db=not args.no_import)
        print(json.dumps(manifest["totals"]))
        return 0
    path = root / "manifest.json"
    if not path.exists():
        print("not built yet", file=sys.stderr)
        return 1
    manifest = json.loads(path.read_text())
    print(json.dumps({"built_at": manifest.get("built_at"), **manifest.get("totals", {})}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
