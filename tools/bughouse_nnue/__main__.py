"""`python3 -m bughouse_nnue <command>` -- build a single-board bughouse NNUE's training data."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


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
    parser = argparse.ArgumentParser(prog="bughouse_nnue", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_setup = sub.add_parser("setup", help="build the pinned data tools, fetch the trainer")
    p_setup.add_argument("--jobs", type=int, default=0, help="make -j (default: all cores)")
    p_setup.add_argument("--arch", help="Makefile ARCH (default: detected from the CPU)")

    p_extract = sub.add_parser("extract", help="replay the archive into plain-text training records")
    p_extract.add_argument("--only", help="years, e.g. 2016,2017 or 2010-2015")
    p_extract.add_argument("--min-elo", type=int, default=1800,
                           help="both players on a board must be rated at least this (default 1800)")
    p_extract.add_argument("--per-board", type=int, default=6,
                           help="positions sampled from each board of a game (default 6)")
    p_extract.add_argument("--min-ply", type=int, default=6,
                           help="skip a board's first plies (default 6)")
    p_extract.add_argument("--other-board", type=float, default=0.5,
                           help="sampling factor for the board the game did not end on (default 0.5)")
    p_extract.add_argument("--validation", type=int, default=2,
                           help="percent of games held out for validation (default 2)")
    p_extract.add_argument("--games", type=int, default=0, help="stop a year after this many games (testing)")
    p_extract.add_argument("--terminations", default="checkmated",
                           help="game endings to learn from, comma-separated: checkmated, resigns, "
                                "'forfeits on time', 'forfeits by disconnection'; 'all' for every "
                                "decisive game (default checkmated)")
    p_extract.add_argument("--any-ply", action="store_true",
                           help="sample any position, not only quiet ones (not in check, move played no capture)")
    p_extract.add_argument("--jobs", type=int, default=0)

    p_score = sub.add_parser("score", help="add a shallow search score to extracted records")
    p_score.add_argument("files", nargs="*", type=Path, help="plain files (default: all unscored)")
    p_score.add_argument("--depth", type=int, default=4)
    p_score.add_argument("--jobs", type=int, default=0, help="engine processes (default: all cores)")

    def game_options(p, per_board: bool) -> None:
        p.add_argument("--nodes", type=int, default=10000, help="search nodes per move (default 10000)")
        p.add_argument("--opening-plies", type=int, default=10,
                       help="plies per board taken from a real archive game to start from (default 10)")
        p.add_argument("--random-plies", type=int, default=0,
                       help="uniformly random opening moves per board (default 0; 8 if no archive)")
        p.add_argument("--max-plies", type=int, default=200,
                       help="abandon a game past this many plies per board (default 200)")
        if per_board:
            p.add_argument("--per-board", type=int, default=8,
                           help="positions sampled per board (default 8; 0 keeps every searched position)")
            p.add_argument("--any-ply", action="store_true", help="keep captures and checks too")
            p.add_argument("--validation", type=int, default=2, help="percent of games held out (default 2)")
        p.add_argument("--seed", type=int)
        p.add_argument("--jobs", type=int, default=0)

    p_self = sub.add_parser("selfplay", help="two-board engine self-play into training records")
    p_self.add_argument("--games", type=int, default=1000)
    p_self.add_argument("--net", type=Path, help="play with this .nnue instead of the hand-written eval")
    game_options(p_self, per_board=True)

    p_match = sub.add_parser("match", help="the gate: one eval against another over whole two-board games")
    p_match.add_argument("--net-one", type=Path, help=".nnue for team one (default: the hand-written eval)")
    p_match.add_argument("--net-two", type=Path, help=".nnue for team two (default: the hand-written eval)")
    p_match.add_argument("--games", type=int, default=200, help="games to play, two per opening (default 200)")
    game_options(p_match, per_board=False)

    p_convert = sub.add_parser("convert", help="interleave the plain files and pack them to .bin")
    p_convert.add_argument("--only", help="years to include (default: all extracted)")
    p_convert.add_argument("--source", help="a non-year source, e.g. selfplay (default: the archive years)")
    p_convert.add_argument("--name", default="pocketknight", help="dataset name (default pocketknight)")
    p_convert.add_argument("--scored", action="store_true", help="use the scored files")

    p_eval = sub.add_parser("evaluate", help="how well an eval predicts held-out outcomes")
    p_eval.add_argument("--net", type=Path, help="an .nnue to test (default: the hand-written eval)")
    p_eval.add_argument("--positions", type=int, default=20000)
    p_eval.add_argument("--depth", type=int, default=1)
    p_eval.add_argument("--only", help="validation years to draw from")
    p_eval.add_argument("--jobs", type=int, default=0)
    p_eval.add_argument("--variant", default=None,
                        help="engine variant for the net (default pocketknight; crazyhouse for its net)")

    p_bundle = sub.add_parser("bundle", help="one folder to upload to Kaggle: dataset, config, train.sh, notebook")
    p_bundle.add_argument("--name", default="pocketknight", help="dataset name (default pocketknight)")
    p_bundle.add_argument("--slug", help="Kaggle dataset slug (default bughouse-nnue-<name>)")
    p_bundle.add_argument("--args", default="",
                          help="extra train.sh options for the notebook, e.g. '--epochs 2 --epoch-size 2000000'")

    sub.add_parser("status", help="what is built, extracted and packed")

    args = parser.parse_args(argv)

    if args.command == "setup":
        from .toolchain import setup
        return setup(args.jobs, args.arch)
    if args.command == "extract":
        from .extract import Settings, extract
        ends = () if args.terminations.strip() == "all" else tuple(
            t.strip() for t in args.terminations.split(",") if t.strip()
        )
        return extract(
            _years(args.only),
            Settings(min_elo=args.min_elo, per_board=args.per_board, min_ply=args.min_ply,
                     other_board=args.other_board, validation_percent=args.validation,
                     max_games=args.games, terminations=ends, quiet_only=not args.any_ply),
            args.jobs,
        )
    if args.command == "score":
        from .score import score_files
        return score_files(args.files, args.depth, args.jobs)
    if args.command == "selfplay":
        from .selfplay import Settings, selfplay
        return selfplay(
            args.games,
            Settings(nodes=args.nodes, opening_plies=args.opening_plies, random_plies=args.random_plies,
                     max_plies=args.max_plies, per_board=args.per_board, quiet_only=not args.any_ply,
                     validation_percent=args.validation, net=str(args.net) if args.net else None),
            args.jobs, args.seed,
        )
    if args.command == "match":
        from .match import match
        from .selfplay import Settings
        return match(
            args.net_one, args.net_two, args.games,
            Settings(nodes=args.nodes, opening_plies=args.opening_plies, random_plies=args.random_plies,
                     max_plies=args.max_plies),
            args.jobs, args.seed,
        )
    if args.command == "convert":
        from .convert import convert
        return convert(_years(args.only), args.name, args.scored, args.source)
    if args.command == "evaluate":
        from .evaluate import evaluate
        return evaluate(args.net, args.positions, args.depth, _years(args.only), args.jobs,
                        args.variant)
    if args.command == "bundle":
        from .bundle import bundle
        return bundle(args.name, args.slug, args.args)
    if args.command == "status":
        from .status import status
        print(json.dumps(status(), indent=2))
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
