"""
Output handling for repertoire lines.

Saves repertoire lines to PGN files.
"""

import os
from datetime import datetime
from typing import List, Optional

import chess
import chess.pgn


class PgnWriter:
    """Handles saving repertoire lines to PGN files."""

    def __init__(
        self,
        output_dir: str = "pgns",
        starting_board: Optional[chess.Board] = None
    ):
        """
        Initialize PGN writer.

        Args:
            output_dir: Directory for output files
            starting_board: Starting position (for FEN header)
        """
        self.output_dir = output_dir
        self.consolidated_file = os.path.join(output_dir, "full_repertoire.pgn")
        self.starting_board = starting_board.copy() if starting_board else chess.Board()

        # Create output directory
        if not os.path.exists(output_dir):
            os.makedirs(output_dir)

        # Clear any existing consolidated file
        if os.path.exists(self.consolidated_file):
            os.remove(self.consolidated_file)

    def save_line(
        self,
        moves: List[str],
        probability: float,
        my_color: chess.Color,
        expected_value: Optional[float] = None
    ):
        """
        Save a single completed line to the consolidated file.

        Args:
            moves: List of SAN moves
            probability: Path probability of this line
            my_color: Your color
            expected_value: Expected value in centipawns (for tricks mode)
        """
        board = self.starting_board.copy()
        game = chess.pgn.Game()

        # Headers
        game.headers["Event"] = "Repertoire Line"
        game.headers["Site"] = "Opening Builder"
        game.headers["Date"] = datetime.now().strftime("%Y.%m.%d")
        game.headers["White"] = "Repertoire" if my_color == chess.WHITE else "Opponent"
        game.headers["Black"] = "Repertoire" if my_color == chess.BLACK else "Opponent"
        game.headers["Result"] = "*"

        # Set up FEN if not starting position (per PGN standard, SetUp must be "1")
        if board.fen() != chess.STARTING_FEN:
            game.headers["SetUp"] = "1"
            game.headers["FEN"] = board.fen()
            game.setup(board)

        # Build comment
        comment_parts = [f"Probability: {probability:.2%}"]
        if expected_value is not None:
            comment_parts.append(f"EV: {expected_value:+.1f}cp")
        game.comment = " | ".join(comment_parts)

        # Add moves
        node = game
        for move_san in moves:
            try:
                move = board.parse_san(move_san)
                node = node.add_variation(move)
                board.push(move)
            except ValueError:
                print(f"    [ERROR] Could not parse move '{move_san}' in: {moves}")
                return

        # Append to consolidated file
        with open(self.consolidated_file, "a") as f:
            f.write(str(game))
            f.write("\n\n")

