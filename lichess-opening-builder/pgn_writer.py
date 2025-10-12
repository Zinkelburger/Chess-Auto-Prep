import os
import chess
import chess.pgn
from typing import List
from datetime import datetime

class PgnWriter:
    """Handles saving repertoire lines to PGN files."""

    def __init__(self, output_dir: str = "pgns"):
        self.output_dir = output_dir
        self.consolidated_file = os.path.join(output_dir, "full_repertoire.pgn")
        if not os.path.exists(output_dir):
            os.makedirs(output_dir)
        # Clear the consolidated file at the start of a run
        if os.path.exists(self.consolidated_file):
            os.remove(self.consolidated_file)

    def save_line(self, moves: List[str], probability: float, my_color: chess.Color):
        """Saves a single completed line to the consolidated file."""
        board = chess.Board()
        game = chess.pgn.Game()
        game.headers["Event"] = "Repertoire Line"
        game.headers["Site"] = "Lichess Opening Builder"
        game.headers["Date"] = datetime.now().strftime("%Y.%m.%d")
        game.headers["White"] = "My Repertoire" if my_color == chess.WHITE else "Opponent"
        game.headers["Black"] = "My Repertoire" if my_color == chess.BLACK else "Opponent"
        game.headers["Result"] = "*"
        game.comment = f"Line Probability: {probability:.2%}"

        node = game
        for move_san in moves:
            try:
                move = board.parse_san(move_san)
                node = node.add_variation(move)
                board.push(move)
            except ValueError:
                print(f"    [ERROR] Could not parse SAN move '{move_san}' in line: {moves}")
                return  # Don't save a broken line

        # Save to consolidated file
        with open(self.consolidated_file, 'a') as f:
            f.write(str(game))
            f.write("\n\n")