"""
Stockfish engine using the stockfish pip package wrapper.

This is an alternative to uci_engine.py that uses the stockfish pip package
instead of direct UCI communication.
"""

import chess
from typing import Optional

try:
    from stockfish import Stockfish
    HAS_STOCKFISH_WRAPPER = True
except ImportError:
    HAS_STOCKFISH_WRAPPER = False


class StockfishWrapper:
    """
    Wrapper around stockfish pip package.

    Note: Still requires stockfish binary to be installed!
    The pip package is just a convenience wrapper.
    """

    def __init__(self, path: str = "stockfish", depth: int = 20):
        if not HAS_STOCKFISH_WRAPPER:
            raise ImportError(
                "stockfish pip package not installed. "
                "Install with: pip install stockfish"
            )

        self.sf = Stockfish(path=path, depth=depth)
        self.depth = depth

    def evaluate(self, board: chess.Board, depth: Optional[int] = None) -> Optional[float]:
        """
        Evaluate a position.

        Args:
            board: Chess board
            depth: Search depth (uses default if None)

        Returns:
            Centipawn evaluation from white's perspective, or None if mate
        """
        if depth:
            self.sf.depth = depth

        self.sf.set_fen_position(board.fen())

        eval_dict = self.sf.get_evaluation()

        # Returns: {'type': 'cp', 'value': 12} or {'type': 'mate', 'value': 1}
        if eval_dict['type'] == 'cp':
            return float(eval_dict['value'])
        elif eval_dict['type'] == 'mate':
            # Convert mate to high score
            mate_in = eval_dict['value']
            return 10000.0 if mate_in > 0 else -10000.0

        return None

    def quit(self):
        """Clean up."""
        # The stockfish package handles cleanup automatically
        pass


# Example usage
if __name__ == "__main__":
    # Still needs binary installed!
    # Fedora: sudo dnf install stockfish
    # Ubuntu: sudo apt install stockfish

    sf = StockfishWrapper()
    board = chess.Board()

    eval_cp = sf.evaluate(board)
    print(f"Starting position eval: {eval_cp:+.1f} cp")

    board.push_san("e4")
    eval_cp = sf.evaluate(board)
    print(f"After e4: {eval_cp:+.1f} cp")
