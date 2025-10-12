#!/usr/bin/env python3
"""
Lichess Opening Builder - Main Entry Point

Build a chess repertoire using Lichess data with different move selection algorithms.
"""

import argparse
import chess
from move_selectors import MoveSelector, MostPopularMoveSelector, HighestWinRateMoveSelector
from pgn_writer import PgnWriter
from repertoire_builder import RepertoireBuilder

def main():
    parser = argparse.ArgumentParser(
        description="Build a chess repertoire using Lichess data.",
        formatter_class=argparse.RawTextHelpFormatter
    )

    parser.add_argument("--color", type=str, choices=['white', 'black'], required=True,
                        help="The color to build the repertoire for.")
    parser.add_argument("--fen", type=str, default=chess.STARTING_FEN,
                        help="The starting FEN of the position to analyze.")
    parser.add_argument("--moves", type=str, default="",
                        help="A space-separated string of initial moves in SAN format (e.g., 'e4 e5').")
    parser.add_argument("--threshold", type=float, default=0.01,
                        help="The minimum cumulative probability for exploring an opponent's line (e.g., 0.01 for 1%).")

    parser.add_argument(
        "--my-move-algo",
        type=str,
        choices=['popular', 'winrate'],
        default='popular',
        help="The algorithm to use for selecting your moves:\n"
             "  popular - Select the most played move (default).\n"
             "  winrate - Select the move with the highest win rate."
    )
    parser.add_argument("--min-games", type=int, default=50,
                        help="Minimum games required for the 'winrate' algorithm.")

    args = parser.parse_args()

    # --- Initialize Components ---
    my_color = chess.WHITE if args.color == 'white' else chess.BLACK

    # Choose and instantiate the selected algorithm
    move_selector: MoveSelector
    if args.my_move_algo == 'popular':
        move_selector = MostPopularMoveSelector()
    elif args.my_move_algo == 'winrate':
        move_selector = HighestWinRateMoveSelector(min_games=args.min_games)

    pgn_writer = PgnWriter(output_dir="pgns")

    # --- Run the Builder ---
    builder = RepertoireBuilder(
        my_color=my_color,
        my_move_selector=move_selector,
        pgn_writer=pgn_writer
    )

    initial_moves = args.moves.split() if args.moves else []

    print("-" * 50)
    print(f"Building repertoire for: {args.color.upper()}")
    print(f"Move Selection Algorithm: {args.my_move_algo.upper()}")
    print(f"Opponent Line Threshold: {args.threshold:.2%}")
    print(f"Starting FEN: {args.fen}")
    if initial_moves:
        print(f"Initial Moves: {' '.join(initial_moves)}")
    print("-" * 50)

    builder.build(
        start_fen=args.fen,
        initial_moves=initial_moves,
        threshold=args.threshold
    )

    print("\n--- Repertoire Analysis Complete ---")
    print(f"Found {builder.completed_lines_count} distinct repertoire lines.")
    print(f"Consolidated repertoire saved to: {pgn_writer.consolidated_file}")

if __name__ == "__main__":
    main()