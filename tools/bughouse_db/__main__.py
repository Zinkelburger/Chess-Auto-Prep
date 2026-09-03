"""`python3 -m bughouse_db <command>` -- fetch, index and query the archive."""

from __future__ import annotations

import argparse
import json
import os
import sys

from . import book as book_api
from . import fetch as fetch_api
from .index import DEFAULT_MAX_PLY, build
from .paths import book_path, corpus_dir


def _years(raw: str | None) -> list[int] | None:
    if not raw:
        return None
    out: list[int] = []
    for part in raw.split(","):
        part = part.strip()
        if "-" in part:
            lo, hi = part.split("-", 1)
            out.extend(range(int(lo), int(hi) + 1))
        elif part:
            out.append(int(part))
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="bughouse_db", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_fetch = sub.add_parser("fetch", help="download the archive")
    p_fetch.add_argument("--only", help="years, e.g. 2016,2017 or 2010-2015")
    p_fetch.add_argument("--force", action="store_true", help="re-download")

    p_check = sub.add_parser("check", help="verify the downloaded archive")
    p_check.add_argument("--sha", action="store_true", help="also verify hashes")

    p_index = sub.add_parser("index", help="build the opening book")
    p_index.add_argument("--only", help="years to index")
    p_index.add_argument("--max-ply", type=int, default=DEFAULT_MAX_PLY)
    p_index.add_argument(
        "--min-games",
        type=int,
        default=2,
        help="drop continuations seen fewer times (default 2)",
    )
    p_index.add_argument("--min-elo", type=int, default=0)
    p_index.add_argument("--jobs", type=int, default=0)

    p_explore = sub.add_parser("explore", help="query a two-board position")
    p_explore.add_argument("--fen-a", required=True)
    p_explore.add_argument("--fen-b", required=True)

    sub.add_parser("status", help="what is downloaded and built")

    args = parser.parse_args(argv)

    if args.command == "fetch":
        return fetch_api.fetch(_years(args.only), args.force)
    if args.command == "check":
        return fetch_api.check(args.sha)
    if args.command == "index":
        return build(
            _years(args.only),
            args.max_ply,
            args.min_games,
            args.min_elo,
            args.jobs,
        )
    if args.command == "explore":
        con = book_api.open_book()
        print(json.dumps(book_api.explore(con, args.fen_a, args.fen_b), indent=2))
        return 0
    if args.command == "status":
        files = sorted(corpus_dir().glob("export*.bpgn.bz2"))
        size = sum(f.stat().st_size for f in files)
        print(f"corpus: {len(files)} year(s), {fetch_api.human(size)} in {corpus_dir()}")
        path = book_path()
        if not path.exists():
            print(f"book:   not built ({path})")
            return 0
        con = book_api.open_book()
        info = book_api.meta(con)
        nodes = con.execute("SELECT COUNT(*) FROM node").fetchone()[0]
        edges = con.execute("SELECT COUNT(*) FROM edge").fetchone()[0]
        mb = os.path.getsize(path) / 1e6
        print(f"book:   {nodes} positions, {edges} continuations, {mb:.1f} MB")
        print(f"        games={info.get('games')} max_ply={info.get('max_ply')} "
              f"min_games={info.get('min_games')} years={info.get('years')}")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
