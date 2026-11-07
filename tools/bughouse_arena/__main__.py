"""Command line for the bughouse arena. Run from tools/:

    python3 -m bughouse_arena \
        --contender hivemind,nodes=400,name=n400 \
        --baseline  hivemind,nodes=100,name=n100 \
        --pairs 50 --sprt-elo0 0 --sprt-elo1 20

A side is ``random[,sit=p]`` or an engine spec ``[KIND,]key=value,...``:

  hivemind   the engine the app ships (also a spec with no kind); ``bin=``,
             ``model=`` and ``lib=`` point at another build, network or ONNX
             Runtime directory
  hypebeast  the HypeBeast fork (``HypeBeast=true``; ``Coordination=false``
             for the ablation); ``bin=``, ``net=`` (EvalFile)
  fsf        unmodified Fairy-Stockfish bughouse via the UCI snapshot
             adapter; ``bin=``, ``net=`` (EvalFile)

``nodes=`` or ``movetime=`` set the search (the Fairy-Stockfish kinds need
one), ``name=`` labels it, and any other ``Option=value`` is sent with
setoption. Measured runs use ``--fixed-sample`` with a pinned opening file:

    python3 -m bughouse_arena --fixed-sample \
        --contender hypebeast,movetime=500 --baseline fsf,movetime=500 \
        --openings bughouse_arena/opening_sets/screen20.txt --pairs 20
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .match import MatchConfig, PlayerFactory, default_ort_threads, load_openings, run_match
from .sim import ClockConfig

DATA = Path.home() / ".local/share/chess-prep/bughouse-arena"


def seconds_range(text: str) -> tuple[int, int]:
    parts = text.split(":")
    if len(parts) not in (1, 2):
        raise argparse.ArgumentTypeError("expected SECONDS or LOW:HIGH")
    values = [round(float(part) * 1000) for part in parts]
    low, high = values[0], values[-1]
    if low <= 0 or high < low:
        raise argparse.ArgumentTypeError("need 0 < LOW <= HIGH")
    return low, high


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python3 -m bughouse_arena",
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engine", type=Path,
                        help="default Hivemind binary for hivemind specs (else the bundled one)")
    parser.add_argument("--contender", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--pairs", type=int, default=10, help="openings; each is played twice")
    parser.add_argument("--clock", type=float, default=120.0, help="seconds per seat (default 120)")
    parser.add_argument("--move-cost", type=seconds_range, default=(1500, 2500),
                        help="virtual seconds per move, fixed or LOW:HIGH uniform (default 1.5:2.5)")
    parser.add_argument("--react-cost", type=float, default=0.5,
                        help="seconds a sitting seat needs to react to the other board (default 0.5)")
    parser.add_argument("--openings", type=Path, help="opening file (move lists or dual FENs)")
    parser.add_argument("--opening-plies", type=int, default=2,
                        help="random plies per board when no --openings (default 2)")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--concurrency", type=int, default=1, help="games played at once")
    parser.add_argument("--ort-threads", type=int,
                        help="ONNX Runtime intra-op threads per engine (default: cores split across games)")
    parser.add_argument("--output", type=Path,
                        help=f"match directory (default {DATA}/<contender>-vs-<baseline>)")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--engine-logs", action="store_true", help="write each process's UCI traffic")
    parser.add_argument("--verbose", action="store_true", help="print every move and sit")
    parser.add_argument("--search-timeout", type=float,
                        help="hard wall-clock seconds per search before the engine is killed and "
                             "the game voided as an engine failure (default 3x movetime + 15 s, "
                             "or 120 s for a node budget)")
    parser.add_argument("--fixed-sample", action="store_true",
                        help="play exactly --pairs pairs, no SPRT stopping, and report the "
                             "pair-aware interval; needs one opening per pair")
    parser.add_argument("--sprt-elo0", type=float, default=0.0)
    parser.add_argument("--sprt-elo1", type=float, default=0.0)
    parser.add_argument("--sprt-alpha", type=float, default=0.05)
    parser.add_argument("--sprt-beta", type=float, default=0.05)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    args = parse_args(argv)
    if args.fixed_sample and args.sprt_elo1 > args.sprt_elo0:
        print("bughouse_arena: --fixed-sample runs do not use SPRT stopping", file=sys.stderr)
        return 2
    ort_threads = args.ort_threads or default_ort_threads(args.concurrency)
    try:
        contender = PlayerFactory(args.contender, args.engine, ort_threads, None)
        baseline = PlayerFactory(args.baseline, args.engine, ort_threads, None)
    except Exception as error:  # bad spec, or no engine installed
        print(f"bughouse_arena: {error}", file=sys.stderr)
        return 1
    contender.search_timeout = baseline.search_timeout = args.search_timeout
    if args.output is None:
        args.output = DATA / f"{contender.name}-vs-{baseline.name}"
    if args.engine_logs:
        contender.log_dir = baseline.log_dir = args.output / "engine_logs"
        contender.log_dir.mkdir(parents=True, exist_ok=True)
    clock = ClockConfig(round(args.clock * 1000), args.move_cost, round(args.react_cost * 1000))
    config = MatchConfig(
        pairs=args.pairs, clock=clock, output=args.output, seed=args.seed,
        openings=load_openings(args.openings) if args.openings else None,
        opening_plies=args.opening_plies, concurrency=args.concurrency,
        resume=args.resume, verbose=args.verbose,
        sprt=((args.sprt_elo0, args.sprt_elo1, args.sprt_alpha, args.sprt_beta)
              if args.sprt_elo1 > args.sprt_elo0 else None),
        fixed_sample=args.fixed_sample, openings_path=args.openings,
        ort_threads=ort_threads, argv=["python3", "-m", "bughouse_arena", *argv])
    try:
        summary = run_match(config, contender, baseline)
    except (RuntimeError, FileExistsError, ValueError) as error:
        print(f"bughouse_arena: {error}", file=sys.stderr)
        return 1
    if args.fixed_sample:
        print(format_fixed_sample(contender.name, baseline.name, summary["fixed_sample"])
              + f"\nterminations {summary['terminations']}"
              + f"\nsummary: {args.output / 'summary.json'}")
        return 0
    elo = summary["contender_elo"]
    interval = summary["elo_confidence_95"]
    print(f"\n{contender.name} vs {baseline.name}: "
          f"+{summary['contender_wins']} -{summary['contender_losses']} ={summary['draws']} "
          f"score {100 * (summary['contender_score'] or 0):.1f}%"
          + (f", elo {elo:+.0f}" if elo is not None else "")
          + (f" (95% CI {interval[0]:+.0f} to {interval[1]:+.0f})" if interval else "")
          + f"\nterminations {summary['terminations']}"
          + f"\nsummary: {args.output / 'summary.json'}")
    return 0


def format_fixed_sample(contender: str, baseline: str, block: dict) -> str:
    def elo(value):
        return "unbounded" if value is None else f"{value:+.0f}"

    lines = [f"\n{contender} vs {baseline}: +{block['wins']} ={block['draws']} -{block['losses']}"
             f" over {block['complete_pairs']}/{block['declared_pairs']} complete pairs"]
    if block["score"] is not None:
        low, high = block["score_interval_95"]
        lines.append(f"score {100 * block['score']:.1f}% (95% CI {100 * low:.1f}% to "
                     f"{100 * high:.1f}%, opening pairs as the unit)")
        point = block["elo"]
        bounds = block["elo_interval_95"]
        lines.append(f"elo {'n/a at 0%/100%' if point is None else f'{point:+.0f}'}"
                     f" (95% CI {elo(bounds[0])} to {elo(bounds[1])})")
    lines.append("pairs " + " ".join(f"{k}:{v}" for k, v in block["pentanomial"].items()))
    reliability = block["reliability"]
    lines.append(f"reliability errors={reliability['errors']} "
                 f"illegal={reliability['illegal_moves']} "
                 f"replayed={reliability['replayed_errors']}"
                 + ("" if reliability["ok"] else "  NOT a clean run"))
    if not block["sample_complete"]:
        lines.append("sample INCOMPLETE: the declared pairs were not all played")
    return "\n".join(lines)


if __name__ == "__main__":
    raise SystemExit(main())
