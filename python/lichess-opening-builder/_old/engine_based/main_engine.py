#!/usr/bin/env python3
"""
Engine-Based Opening Builder - Find Tricky Opening Lines

Uses Stockfish for evaluation and probability providers (Lichess API or Maia2)
for human move probabilities to find opening lines where opponents are likely
to make mistakes.

Architecture:
1. Build tree with move probabilities (from Lichess or Maia2)
2. Evaluate leaf nodes with Stockfish
3. Propagate expected values back up
4. Find lines with highest expected value
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
from simple_search import search_for_tricks
from stockfish_helper import get_or_install_stockfish
from pgn_writer import PgnWriter
from hybrid_probability import HybridProbability

# Load environment variables
load_dotenv()


def evaluate_position_only(board, my_color, probability_provider, stockfish, player_elo, opponent_elo):
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

    move_probs = probability_provider.get_move_probabilities(
        board,
        player_elo=elo_to_move,
        opponent_elo=elo_opponent,
        min_probability=0.001  # Show ALL moves (>0.1% probability)
    )

    if not move_probs:
        print("\nNo legal moves found.")
        return

    # Sort by probability
    sorted_moves = sorted(move_probs.items(), key=lambda x: x[1], reverse=True)

    print(f"\n{'Your' if is_my_turn else 'Opponent'} moves (predicted @ {elo_to_move} ELO):")
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
    parser.add_argument("--top-candidates", type=int, default=8,
                        help="Top N moves by probability to evaluate for your moves (default: 8).")
    parser.add_argument("--my-move-threshold", type=float, default=50.0,
                        help="Explore your moves within this many cp of best move (default: 50).")
    parser.add_argument("--opponent-min-prob", type=float, default=0.10,
                        help="Minimum probability for opponent moves (default: 0.10 = 10%%).")

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

    # Lichess API parameters
    parser.add_argument("--use-lichess", action="store_true",
                        help="Use Lichess API for real game statistics (falls back to Maia2 if no data).")
    parser.add_argument("--lichess-min-games", type=int, default=100,
                        help="Minimum games required from Lichess API (default: 100).")
    parser.add_argument("--lichess-rating-min", type=int, default=1800,
                        help="Minimum rating for Lichess games (default: 1800).")
    parser.add_argument("--lichess-rating-max", type=int, default=None,
                        help="Maximum rating for Lichess games (default: None).")
    parser.add_argument("--lichess-speeds", type=str, default="blitz,rapid,classical",
                        help="Comma-separated game speeds for Lichess (default: 'blitz,rapid,classical').")

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

        print(f"Loading Maia2 model ({args.maia_type}, {args.device})...")
        maia_model = Maia2(
            game_type=args.maia_type,
            device=args.device,
            default_elo=args.player_elo
        )

        # Setup probability provider (Lichess API + Maia2 fallback, or just Maia2)
        if args.use_lichess:
            print("Enabling Lichess API for real game statistics...")
            lichess_rating_range = None
            if args.lichess_rating_min or args.lichess_rating_max:
                rating_min = args.lichess_rating_min if args.lichess_rating_min else 0
                rating_max = args.lichess_rating_max if args.lichess_rating_max else 3000
                lichess_rating_range = (rating_min, rating_max)
                if args.lichess_rating_max:
                    print(f"  Rating range: {args.lichess_rating_min}-{args.lichess_rating_max}")
                else:
                    print(f"  Rating: {args.lichess_rating_min}+")

            lichess_speeds = None
            if args.lichess_speeds:
                lichess_speeds = args.lichess_speeds.split(',')
                print(f"  Speeds: {', '.join(lichess_speeds)}")

            print(f"  Min games: {args.lichess_min_games}")
            print(f"  Fallback: Maia2 @ {args.player_elo} ELO")

            probability_provider = HybridProbability(
                maia2_model=maia_model,
                use_lichess=True,
                lichess_min_games=args.lichess_min_games,
                lichess_rating_range=lichess_rating_range,
                lichess_speeds=lichess_speeds
            )
        else:
            probability_provider = maia_model

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
    print(f"  Your moves: evaluate top {args.top_candidates}, keep moves within {args.my_move_threshold:.0f} cp of best")
    print(f"  Opponent moves: all with >{args.opponent_min_prob:.0%} probability")
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
            probability_provider=probability_provider,
            stockfish=stockfish,
            player_elo=args.player_elo,
            opponent_elo=args.opponent_elo
        )
        stockfish.quit()
        return

    # Simple search for tricky positions
    try:
        print("\n[SEARCHING] Looking for tricky positions...")
        print(f"  Min expected value: {args.min_value:+.0f} cp")
        print(f"  Max depth: {args.depth} ply")
        print(f"  Min probability threshold: {args.min_prob:.1%}")

        interesting_positions = search_for_tricks(
            board=board,
            probability_provider=probability_provider,
            stockfish_engine=stockfish,
            my_color=my_color,
            player_elo=args.player_elo,
            opponent_elo=args.opponent_elo,
            max_depth=args.depth,
            min_probability=args.min_prob,
            min_ev_cp=args.min_value,
            top_n_candidates=args.top_candidates,
            my_move_threshold_cp=args.my_move_threshold,
            opponent_min_prob=args.opponent_min_prob
        )

        # Sort by expected value (best first)
        interesting_positions.sort(key=lambda x: x.expected_value, reverse=True)

        # Limit to max_lines
        interesting_positions = interesting_positions[:args.max_lines]

        print(f"\n\nFound {len(interesting_positions)} interesting positions")

        # Save lines to PGN
        if interesting_positions:
            print("\n[SAVING] Writing lines to PGN...")
            pgn_writer = PgnWriter(output_dir="pgns_engine", starting_board=board)

            for i, pos in enumerate(interesting_positions, 1):
                print(f"\n  [Line {i}] EV: {pos.expected_value:+.1f} cp, Prob: {pos.probability:.2%}")
                print(f"    {' '.join(pos.line)}")

                # Save to PGN
                pgn_writer.save_line(
                    pos.line,
                    pos.probability,
                    my_color,
                    stockfish_eval=pos.expected_value,
                    expected_value=pos.expected_value
                )

            print(f"\nAll lines saved to: {pgn_writer.consolidated_file}")
        else:
            print(f"\nNo positions found with expected value >= {args.min_value:+.0f} cp")

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
