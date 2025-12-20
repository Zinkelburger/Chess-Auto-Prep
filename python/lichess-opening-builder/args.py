"""
Command-line argument parsing for the Opening Builder.
"""

import argparse
import chess


def parse_args():
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Build chess opening repertoires and find tricky lines.",
        formatter_class=argparse.RawTextHelpFormatter
    )

    # === Required ===
    parser.add_argument(
        "--color", type=str, choices=["white", "black"], required=True,
        help="The color to build the repertoire for."
    )

    # === Mode Selection ===
    parser.add_argument(
        "--mode", type=str, choices=["coverage", "tricks", "pressure"], default="coverage",
        help="Mode of operation:\n"
             "  coverage  - Build complete repertoire covering all common lines (default)\n"
             "  tricks    - Find positions where opponent is likely to blunder\n"
             "  pressure  - Find lines with sustained pressure (low survival probability)"
    )

    # === Starting Position ===
    parser.add_argument(
        "--fen", type=str, default=chess.STARTING_FEN,
        help="The starting FEN of the position to analyze."
    )
    parser.add_argument(
        "--moves", type=str, default="",
        help="Initial moves in SAN format (e.g., 'e4 e5 Nf3')."
    )

    # === Coverage Mode Parameters ===
    coverage_group = parser.add_argument_group("Coverage Mode Options")
    coverage_group.add_argument(
        "--threshold", type=float, default=0.01,
        help="Minimum path probability to explore a line (default: 0.01 = 1%%)."
    )
    coverage_group.add_argument(
        "--my-move-algo", type=str, choices=["popular", "winrate"], default="popular",
        help="Algorithm for selecting your moves:\n"
             "  popular - Select the most played move (default)\n"
             "  winrate - Select the move with highest win rate"
    )
    coverage_group.add_argument(
        "--winrate-min-games", type=int, default=50,
        help="Minimum games required for winrate algorithm (default: 50)."
    )

    # === Tricks Mode Parameters ===
    tricks_group = parser.add_argument_group("Tricks Mode Options")
    tricks_group.add_argument(
        "--min-ev", type=float, default=50.0,
        help="Minimum expected value in centipawns to save a line (default: 50)."
    )
    tricks_group.add_argument(
        "--max-depth", type=int, default=20,
        help="Maximum search depth in ply (default: 20)."
    )
    tricks_group.add_argument(
        "--top-candidates", type=int, default=8,
        help="Top N moves by probability to evaluate for your moves (default: 8)."
    )
    tricks_group.add_argument(
        "--my-move-threshold", type=float, default=50.0,
        help="Explore your moves within this many cp of best move (default: 50)."
    )
    tricks_group.add_argument(
        "--opponent-min-prob", type=float, default=0.10,
        help="Minimum probability for opponent moves (default: 0.10 = 10%%)."
    )
    tricks_group.add_argument(
        "--max-lines", type=int, default=None,
        help="Maximum number of lines to output (default: all lines)."
    )
    tricks_group.add_argument(
        "--eval-only", action="store_true",
        help="Just evaluate the position, don't search for tricks."
    )

    # === Probability Source ===
    prob_group = parser.add_argument_group("Probability Source")
    prob_group.add_argument(
        "--use-maia", action="store_true",
        help="Use Maia2 neural network for move probabilities (tricks mode default)."
    )
    prob_group.add_argument(
        "--maia-type", type=str, default="rapid", choices=["rapid", "blitz"],
        help="Maia2 model type (default: rapid)."
    )
    prob_group.add_argument(
        "--device", type=str, default="cpu", choices=["cpu", "gpu"],
        help="Device for Maia2 (default: cpu)."
    )

    # === ELO Parameters ===
    elo_group = parser.add_argument_group("ELO Ratings")
    elo_group.add_argument(
        "--player-elo", type=int, default=2000,
        help="Your ELO rating for Maia2 predictions (default: 2000)."
    )
    elo_group.add_argument(
        "--opponent-elo", type=int, default=2000,
        help="Opponent's ELO rating for Maia2 predictions (default: 2000)."
    )

    # === Lichess API Parameters ===
    lichess_group = parser.add_argument_group("Lichess API Options")
    lichess_group.add_argument(
        "--lichess-min-games", type=int, default=100,
        help="Minimum games required from Lichess API (default: 100)."
    )
    lichess_group.add_argument(
        "--lichess-ratings", type=str, default="1800,2000,2200,2500",
        help="Comma-separated rating brackets for Lichess (default: '1800,2000,2200,2500')."
    )
    lichess_group.add_argument(
        "--lichess-speeds", type=str, default="blitz,rapid,classical",
        help="Comma-separated game speeds for Lichess (default: 'blitz,rapid,classical')."
    )

    # === Filtering ===
    filter_group = parser.add_argument_group("Move Filtering")
    filter_group.add_argument(
        "--min-move-frequency", type=float, default=0.005,
        help="Minimum frequency for a move to be considered (default: 0.005 = 0.5%%)."
    )
    filter_group.add_argument(
        "--min-position-games", type=int, default=100,
        help="Minimum games in a position to continue exploring (default: 100)."
    )

    # === Engine ===
    engine_group = parser.add_argument_group("Engine Options")
    engine_group.add_argument(
        "--stockfish", type=str, default=None,
        help="Path to Stockfish engine (default: auto-detect or from .env)."
    )

    # === Pressure Mode Parameters ===
    pressure_group = parser.add_argument_group("Pressure Mode Options")
    pressure_group.add_argument(
        "--line-depth", type=int, default=10,
        help="How many ply (half-moves) deep to search (default: 10 = 5 full moves)."
    )
    pressure_group.add_argument(
        "--min-eval", type=float, default=None,
        help="Minimum acceptable eval in centipawns from your perspective.\n"
             "Default: 0 for White (won't accept worse), -50 for Black (ok if slightly worse)."
    )
    pressure_group.add_argument(
        "--max-eval", type=float, default=200.0,
        help="Maximum eval to explore (default: 200cp). Above this, position is 'won' - prune."
    )

    # === Output ===
    output_group = parser.add_argument_group("Output Options")
    output_group.add_argument(
        "--output-dir", type=str, default="pgns",
        help="Directory for output PGN files (default: 'pgns')."
    )

    return parser.parse_args()


def get_starting_position(args) -> chess.Board:
    """Get the starting position after applying initial moves."""
    board = chess.Board(args.fen)
    
    if args.moves:
        for move_san in args.moves.split():
            try:
                board.push_san(move_san)
            except ValueError as e:
                raise ValueError(f"Invalid move '{move_san}' in initial moves: {e}")
    
    return board


def get_my_color(args) -> chess.Color:
    """Get the color enum from args."""
    return chess.WHITE if args.color == "white" else chess.BLACK

