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
from tree_search import (
    build_tree_incremental,
    calculate_expected_values,
    find_best_lines,
    print_tree_stats
)
from stockfish_helper import get_or_install_stockfish
from pgn_writer import PgnWriter

# Load environment variables
load_dotenv()


def evaluate_position_only(board, my_color, maia2, stockfish, player_elo, opponent_elo):
    """
    Evaluate a single position and show all children with probabilities and evals.
    """
    print("\n" + "=" * 70)
    print("POSITION EVALUATION")
    print("=" * 70)
    print(f"FEN: {board.fen()}")
    print(f"Turn: {'White' if board.turn == chess.WHITE else 'Black'}")

    # Evaluate current position
    current_eval = stockfish.evaluate(board, depth=20, pov_color=my_color)
    if current_eval is None:
        current_eval = 0.0
    print(f"Current eval: {current_eval:+.1f} cp (from your perspective)")

    # Get move probabilities
    is_my_turn = (board.turn == my_color)
    if is_my_turn:
        elo_to_move = player_elo
        elo_opponent = opponent_elo
    else:
        elo_to_move = opponent_elo
        elo_opponent = player_elo

    move_probs = maia2.get_move_probabilities(
        board,
        player_elo=elo_to_move,
        opponent_elo=elo_opponent,
        min_probability=0.10  # Show moves with >10% probability
    )

    if not move_probs:
        print("\nNo legal moves found.")
        return

    # Sort by probability
    sorted_moves = sorted(move_probs.items(), key=lambda x: x[1], reverse=True)

    print(f"\n{'Your' if is_my_turn else 'Opponent'} moves (Maia2 @ {elo_to_move} ELO):")
    print("-" * 70)

    # Evaluate each child
    children_data = []
    for move_san, prob in sorted_moves:
        child_board = board.copy()
        child_board.push_san(move_san)
        child_eval = stockfish.evaluate(child_board, depth=20, pov_color=my_color)
        if child_eval is None:
            child_eval = 0.0
        children_data.append((move_san, prob, child_eval))

        print(f"  {move_san:8s}  Prob: {prob:6.1%}  Eval: {child_eval:+7.1f} cp")

    # Calculate expected value (always probability-weighted)
    total_prob = sum(prob for _, prob, _ in children_data)
    expected_value = sum(prob * ev for _, prob, ev in children_data) / total_prob

    print("\n" + "-" * 70)
    if is_my_turn:
        best_move_eval = max(ev for _, _, ev in children_data)
        print(f"Your turn (you play according to Maia2 probabilities):")
        print(f"  Best move eval:              {best_move_eval:+.1f} cp")
        print(f"  Expected value (weighted):   {expected_value:+.1f} cp")
        print(f"  Difference (your mistakes):  {best_move_eval - expected_value:+.1f} cp")
    else:
        best_defense = min(ev for _, _, ev in children_data)
        print(f"Opponent's turn:")
        print(f"  Best defense (min eval):     {best_defense:+.1f} cp")
        print(f"  Expected value (weighted):   {expected_value:+.1f} cp")
        print(f"  Difference (their mistakes): {expected_value - best_defense:+.1f} cp")

    print("=" * 70)


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
    parser.add_argument("--min-prob", type=float, default=0.10,
                        help="Minimum probability for your moves (default: 0.10 = 10%%).")
    parser.add_argument("--top-my-moves", type=int, default=3,
                        help="Number of your moves to explore (default: 3).")
    parser.add_argument("--top-opp-moves", type=int, default=None,
                        help="Number of opponent moves to explore (default: None, uses --min-prob-opponent).")
    parser.add_argument("--min-prob-opponent", type=float, default=0.2,
                        help="Minimum probability for opponent moves (default: 0.2 = 20%%).")
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
    parser.add_argument("--min-value", type=float, default=0.0,
                        help="Minimum expected value (cp) to save a line (default: 0cp).")
    parser.add_argument("--max-lines", type=int, default=50,
                        help="Maximum number of lines to output (default: 50).")
    parser.add_argument("--eval-only", action="store_true",
                        help="Just evaluate the position and show children with expected value (no tree search).")

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
    if args.top_opp_moves is not None:
        print(f"  Opponent moves to explore: top {args.top_opp_moves}")
    else:
        print(f"  Opponent moves to explore: all with >{args.min_prob_opponent:.0%} probability")
    print(f"  Min probability: {args.min_prob}")
    print(f"  Prune bad moves: {args.prune_bad_moves} cp" if args.prune_bad_moves > 0 else "  Prune bad moves: disabled")
    print(f"  Prune winning: {args.prune_winning} cp" if args.prune_winning > 0 else "  Prune winning: disabled")
    print(f"  Prune opponent blunders: {args.prune_opponent_blunders} cp" if args.prune_opponent_blunders > 0 else "  Prune opponent blunders: disabled")
    print(f"  Player ELO: {args.player_elo}")
    print(f"  Opponent ELO: {args.opponent_elo}")
    print(f"  Min expected value: {args.min_value:+.0f} cp")
    print(f"  Max lines to output: {args.max_lines}")
    print("=" * 70)

    # Check if we're just evaluating one position
    if args.eval_only:
        evaluate_position_only(
            board=board,
            my_color=my_color,
            maia2=maia2,
            stockfish=stockfish,
            player_elo=args.player_elo,
            opponent_elo=args.opponent_elo
        )
        stockfish.quit()
        return

    # Analyze opening (full tree search)
    try:
        # Disable pruning if threshold is 0
        prune_bad_moves = args.prune_bad_moves if args.prune_bad_moves > 0 else None
        prune_winning = args.prune_winning if args.prune_winning > 0 else None
        prune_opponent_blunders = args.prune_opponent_blunders if args.prune_opponent_blunders > 0 else None

        # Build tree (consuming the generator to get the final root)
        print("\n[PHASE 1] Building tree with Maia2 probabilities and Stockfish evaluations...")
        tree_gen = build_tree_incremental(
            start_board=board,
            maia2_model=maia2,
            stockfish_engine=stockfish,
            max_depth=args.depth,
            my_color=my_color,
            min_probability=args.min_prob,
            top_n_my_moves=args.top_my_moves,
            top_n_opponent_moves=args.top_opp_moves,
            min_probability_opponent=args.min_prob_opponent,
            player_elo=args.player_elo,
            opponent_elo=args.opponent_elo,
            prune_bad_moves_cp=prune_bad_moves,
            prune_winning_cp=prune_winning,
            prune_opponent_blunders_cp=prune_opponent_blunders
        )

        # Consume the generator - it yields leaves during build, then returns root
        try:
            while True:
                next(tree_gen)
        except StopIteration as e:
            # The return value is in e.value
            root = e.value

        if root is None:
            print("Error: Failed to build tree")
            return

        print("\n[PHASE 2] Calculating expected values...")
        calculate_expected_values(root, my_color)

        print("\n[PHASE 3] Finding best lines...")
        best_lines = find_best_lines(root, my_color, min_value=args.min_value)

        # Limit to max_lines
        best_lines = best_lines[:args.max_lines]

        print(f"\nFound {len(best_lines)} lines with expected value >= {args.min_value:+.0f} cp")

        # Print final statistics
        print("\n" + "=" * 70)
        print_tree_stats(root)
        print("=" * 70)

        # Save lines to PGN
        if best_lines:
            print("\n[PHASE 4] Saving lines to PGN...")
            pgn_writer = PgnWriter(output_dir="pgns_engine", starting_board=board)

            for i, (node, expected_value) in enumerate(best_lines, 1):
                moves = node.get_line()
                line_probability = node.get_line_probability()
                stockfish_eval = node.eval_cp if node.eval_cp is not None else 0.0

                print(f"\n  [Line {i}] Expected Value: {expected_value:+.1f} cp, Probability: {line_probability:.2%}")
                print(f"    {' '.join(moves)}")

                # Save to PGN
                pgn_writer.save_line(
                    moves,
                    line_probability,
                    my_color,
                    stockfish_eval=stockfish_eval,
                    expected_value=expected_value
                )

            print(f"\nAll lines saved to: {pgn_writer.consolidated_file}")
        else:
            print(f"\nNo lines found with expected value >= {args.min_value:+.0f} cp")

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
