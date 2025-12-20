#!/usr/bin/env python3
"""
Opening Builder - Build chess opening repertoires

Modes:
  coverage - Build complete repertoire covering all common opponent responses
  tricks   - Find tricky lines where opponent is likely to blunder

Examples:
  # Build a White repertoire starting with 1.e4
  python main.py --color white --mode coverage --moves "e4" --threshold 0.01

  # Find tricks in the Italian Game
  python main.py --color white --mode tricks --moves "e4 e5 Nf3 Nc6 Bc4" --min-ev 50

  # Evaluate a single position
  python main.py --color white --mode tricks --moves "e4 e5" --eval-only
"""

import chess

from args import parse_args, get_starting_position, get_my_color
from probability import create_provider
from evaluation import create_engine
from selectors import create_selector
from output import PgnWriter
from builder import RepertoireBuilder


def print_config(args, board: chess.Board):
    """Print configuration summary."""
    print("=" * 70)
    print(f"OPENING BUILDER - {args.mode.upper()} MODE")
    print("=" * 70)
    print(f"Color: {args.color.upper()}")
    print(f"Starting FEN: {args.fen}")
    if args.moves:
        print(f"Initial moves: {args.moves}")
        print(f"Position: {board.fen()}")

    if args.mode == "coverage":
        print(f"\nCoverage Settings:")
        print(f"  Path probability threshold: {args.threshold:.1%}")
        print(f"  Your move algorithm: {args.my_move_algo}")
        print(f"  Min move frequency: {args.min_move_frequency:.2%}")
        print(f"  Min position games: {args.min_position_games}")
    else:
        print(f"\nTricks Settings:")
        print(f"  Min expected value: {args.min_ev:+.0f} cp")
        print(f"  Max depth: {args.max_depth} ply")
        print(f"  Top candidates: {args.top_candidates}")
        print(f"  Your move threshold: {args.my_move_threshold:.0f} cp")
        print(f"  Opponent min prob: {args.opponent_min_prob:.0%}")
        print(f"  Player ELO: {args.player_elo}")
        print(f"  Opponent ELO: {args.opponent_elo}")

    print("=" * 70)


def main():
    args = parse_args()

    # Get starting position
    try:
        board = get_starting_position(args)
    except ValueError as e:
        print(f"Error: {e}")
        return 1

    my_color = get_my_color(args)
    initial_moves = args.moves.split() if args.moves else []

    # Print configuration
    print_config(args, board)

    # Create components
    print("\nInitializing...")

    try:
        probability_provider = create_provider(args)
        engine = create_engine(args)
        move_selector = create_selector(args) if args.mode == "coverage" else None

        # Create starting board for PGN (before initial moves)
        starting_board = chess.Board(args.fen)
        pgn_writer = PgnWriter(output_dir=args.output_dir, starting_board=starting_board)

        # Create builder
        builder = RepertoireBuilder(
            my_color=my_color,
            probability_provider=probability_provider,
            pgn_writer=pgn_writer,
            move_selector=move_selector,
            engine=engine,
            min_move_frequency=args.min_move_frequency,
            min_position_games=args.min_position_games
        )

        # Run the appropriate mode
        if args.mode == "coverage":
            print("\n[BUILDING] Complete repertoire coverage...")
            builder.build_coverage(
                start_board=board,
                threshold=args.threshold,
                initial_moves=initial_moves
            )
            print(f"\n✓ Found {builder.completed_lines_count} repertoire lines")
            print(f"✓ Saved to: {pgn_writer.consolidated_file}")

        elif args.mode == "tricks":
            if args.eval_only:
                builder.evaluate_position(
                    board=board,
                    player_elo=args.player_elo,
                    opponent_elo=args.opponent_elo
                )
            else:
                print("\n[SEARCHING] Looking for tricky positions...")
                positions = builder.build_tricks(
                    start_board=board,
                    player_elo=args.player_elo,
                    opponent_elo=args.opponent_elo,
                    min_ev=args.min_ev,
                    max_depth=args.max_depth,
                    min_probability=args.opponent_min_prob,
                    top_candidates=args.top_candidates,
                    my_move_threshold_cp=args.my_move_threshold,
                    opponent_min_prob=args.opponent_min_prob,
                    max_lines=args.max_lines,
                    initial_moves=initial_moves
                )

                print(f"\n✓ Found {len(positions)} interesting positions")

                if positions:
                    print("\n[SAVING] Writing lines to PGN...")
                    for i, pos in enumerate(positions, 1):
                        print(f"  [{i}] EV: {pos.expected_value:+.1f} cp, Prob: {pos.probability:.2%}")
                        print(f"      {' '.join(pos.line)}")
                        pgn_writer.save_line(
                            pos.line,
                            pos.probability,
                            my_color,
                            expected_value=pos.expected_value
                        )
                    print(f"\n✓ Saved to: {pgn_writer.consolidated_file}")

    except KeyboardInterrupt:
        print("\n\nInterrupted by user.")
        return 1
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
        return 1
    finally:
        if engine:
            print("\nShutting down engine...")
            engine.quit()

    print("\nDone!")
    return 0


if __name__ == "__main__":
    exit(main())

