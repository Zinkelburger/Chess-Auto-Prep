#!/usr/bin/env python3
"""
Engine-Based Opening Builder - Find Tricky Opening Lines

Uses Stockfish for evaluation and Maia2 for human move probabilities
to find opening lines where opponents are likely to make mistakes.

Architecture:
1. Build tree with Maia2 move probabilities
2. Evaluate leaf nodes with Stockfish
3. Propagate expected values back up
4. Find lines with highest "trickiness"
"""

import argparse
import chess
import os
import sys

# Add parent directory to path to import from lichess-opening-builder
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from dotenv import load_dotenv
from uci_engine import UCIEngine
from maia2_wrapper import Maia2
from tree_search import build_tree_incremental, print_tree_stats
from stockfish_helper import get_or_install_stockfish
from pgn_writer import PgnWriter

# Load environment variables
load_dotenv()


def main():
    parser = argparse.ArgumentParser(
        description="Find tricky opening lines using Maia2 and Stockfish.",
        formatter_class=argparse.RawTextHelpFormatter
    )

    parser.add_argument("--color", type=str, choices=['white', 'black'], required=True,
                        help="The color to build the repertoire for.")
    parser.add_argument("--fen", type=str, default=chess.STARTING_FEN,
                        help="The starting FEN of the position to analyze.")
    parser.add_argument("--moves", type=str, default="",
                        help="Initial moves in SAN format (e.g., 'e4 e5').")

    # Tree building parameters
    parser.add_argument("--depth", type=int, default=20,
                        help="Maximum depth in ply/half-moves (default: 20).")
    parser.add_argument("--min-prob", type=float, default=0.1,
                        help="Minimum probability for moves (default: 0.1).")
    parser.add_argument("--top-my-moves", type=int, default=3,
                        help="Number of your moves to explore (default: 3).")
    parser.add_argument("--top-opp-moves", type=int, default=5,
                        help="Number of opponent moves to explore (default: 5).")
    parser.add_argument("--prune-bad-moves", type=float, default=100.0,
                        help="Max eval drop (cp) from ROOT allowed for your moves (default: 100, 0 = disable).")
    parser.add_argument("--prune-winning", type=float, default=100.0,
                        help="Stop exploring if improved by this much (cp) from ROOT (default: 100, 0 = disable).")
    parser.add_argument("--prune-opponent-blunders", type=float, default=200.0,
                        help="Stop exploring after opponent blunders by this much (cp) (default: 200, 0 = disable).")

    # ELO parameters
    parser.add_argument("--player-elo", type=int, default=2000,
                        help="Your ELO rating (default: 2000).")
    parser.add_argument("--opponent-elo", type=int, default=2000,
                        help="Opponent's ELO rating (default: 2000).")

    # Engine parameters
    parser.add_argument("--stockfish", type=str, default=None,
                        help="Path to Stockfish engine (default: from .env).")
    parser.add_argument("--maia-type", type=str, default="rapid", choices=['rapid', 'blitz'],
                        help="Maia2 model type (default: rapid).")
    parser.add_argument("--device", type=str, default="cpu", choices=['cpu', 'gpu'],
                        help="Device for Maia2 (default: cpu).")

    # Output parameters
    parser.add_argument("--criterion", type=str, default="trickiness",
                        choices=['trickiness', 'eval', 'expected_value'],
                        help="How to rank lines (default: trickiness).")
    parser.add_argument("--min-trickiness", type=float, default=0.0,
                        help="Minimum trickiness (cp) to save a line (default: 0, saves all lines).")

    args = parser.parse_args()

    # Get stockfish path (try to find or install it)
    env_stockfish = args.stockfish or os.getenv("STOCKFISH_PATH")
    stockfish_path = get_or_install_stockfish(env_stockfish)

    if not stockfish_path:
        print("\nError: Could not find or install Stockfish.")
        print("Please install manually or set STOCKFISH_PATH in .env")
        return

    # Initialize engines
    print("=" * 70)
    print("INITIALIZING ENGINES")
    print("=" * 70)

    try:
        print(f"Loading Stockfish from: {stockfish_path}")
        stockfish = UCIEngine(stockfish_path, name="Stockfish")

        print(f"Loading Maia2 ({args.maia_type}, {args.device})...")
        maia2 = Maia2(
            game_type=args.maia_type,
            device=args.device,
            default_elo=args.player_elo
        )

    except Exception as e:
        print(f"Error initializing engines: {e}")
        import traceback
        traceback.print_exc()
        return

    # Setup starting position
    my_color = chess.WHITE if args.color == 'white' else chess.BLACK
    board = chess.Board(args.fen)

    # Apply initial moves if provided
    initial_moves = args.moves.split() if args.moves else []
    for move in initial_moves:
        board.push_san(move)

    print("\n" + "=" * 70)
    print(f"ANALYZING OPENING FOR {args.color.upper()}")
    print("=" * 70)
    print(f"Starting Position: {args.fen}")
    if initial_moves:
        print(f"Initial Moves: {' '.join(initial_moves)}")
    print(f"\nParameters:")
    print(f"  Max Depth: {args.depth} ply")
    print(f"  Your moves to explore: {args.top_my_moves}")
    print(f"  Opponent moves to explore: {args.top_opp_moves}")
    print(f"  Min probability: {args.min_prob}")
    print(f"  Prune bad moves: {args.prune_bad_moves} cp" if args.prune_bad_moves > 0 else "  Prune bad moves: disabled")
    print(f"  Prune winning: {args.prune_winning} cp" if args.prune_winning > 0 else "  Prune winning: disabled")
    print(f"  Prune opponent blunders: {args.prune_opponent_blunders} cp" if args.prune_opponent_blunders > 0 else "  Prune opponent blunders: disabled")
    print(f"  Player ELO: {args.player_elo}")
    print(f"  Opponent ELO: {args.opponent_elo}")
    print(f"  Ranking criterion: {args.criterion}")
    print(f"  Min trickiness to save: {args.min_trickiness} cp" if args.min_trickiness > 0 else "  Min trickiness: saving all lines")
    print("=" * 70)

    # Analyze opening
    try:
        # Disable pruning if threshold is 0
        prune_bad_moves = args.prune_bad_moves if args.prune_bad_moves > 0 else None
        prune_winning = args.prune_winning if args.prune_winning > 0 else None
        prune_opponent_blunders = args.prune_opponent_blunders if args.prune_opponent_blunders > 0 else None

        # Initialize PGN writer for incremental saving
        pgn_writer = PgnWriter(output_dir="pgns_engine", starting_board=board)
        print(f"Saving lines incrementally to: {pgn_writer.consolidated_file}")

        # Build tree and process lines incrementally
        print("Building tree with Maia2 probabilities...")
        lines_found = 0
        lines_saved = 0

        tree_generator = build_tree_incremental(
            start_board=board,
            maia2_model=maia2,
            stockfish_engine=stockfish,
            max_depth=args.depth,
            my_color=my_color,
            min_probability=args.min_prob,
            top_n_my_moves=args.top_my_moves,
            top_n_opponent_moves=args.top_opp_moves,
            player_elo=args.player_elo,
            opponent_elo=args.opponent_elo,
            prune_bad_moves_cp=prune_bad_moves,
            prune_winning_cp=prune_winning,
            prune_opponent_blunders_cp=prune_opponent_blunders
        )

        # Get root eval for trickiness calculation
        root_eval = stockfish.evaluate(board, depth=20)
        if root_eval is None:
            root_eval = 0.0

        # Process each leaf as it's discovered
        for leaf_node in tree_generator:
            if isinstance(leaf_node, tuple):
                # This is the final return (root, None), skip it
                continue

            lines_found += 1
            moves = leaf_node.get_line()
            eval_cp = leaf_node.eval_cp if leaf_node.eval_cp is not None else 0.0
            line_probability = leaf_node.get_line_probability()

            # Calculate trickiness: how much better is this line than the starting position?
            # From your perspective (positive = good for you)
            if my_color == chess.WHITE:
                trickiness = eval_cp - root_eval  # Higher eval = better for white
            else:
                trickiness = root_eval - eval_cp  # Lower eval = better for black

            # Print the line as it's found
            print(f"\n  [Line {lines_found}] {' '.join(moves)}")
            print(f"    Probability: {line_probability:.2%}, Eval: {eval_cp:+.2f}cp, Trickiness: {trickiness:+.2f}cp")

            # Only save if trickiness meets threshold
            if trickiness >= args.min_trickiness:
                pgn_writer.save_line(moves, line_probability, my_color,
                                    trickiness=trickiness, eval_cp=eval_cp)
                lines_saved += 1
            else:
                print(f"    [SKIPPED] Trickiness {trickiness:+.2f} below threshold {args.min_trickiness}")

        # Get the completed tree (returned at the end of generator)
        tree_root = tree_generator.send(None) if hasattr(tree_generator, 'send') else None

        # Print final statistics
        print("\n" + "=" * 70)
        if tree_root:
            print_tree_stats(tree_root)
        print(f"\nTotal lines explored: {lines_found}")
        print(f"Lines saved (trickiness >= {args.min_trickiness}): {lines_saved}")
        print(f"All lines saved to: {pgn_writer.consolidated_file}")
        print("=" * 70)

    except KeyboardInterrupt:
        print("\n\nSearch interrupted by user.")
    except Exception as e:
        print(f"\nError during analysis: {e}")
        import traceback
        traceback.print_exc()
    finally:
        # Clean up engines
        print("\nShutting down engines...")
        stockfish.quit()
        print("Done!")


if __name__ == "__main__":
    main()
