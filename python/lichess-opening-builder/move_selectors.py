from abc import ABC, abstractmethod
from typing import List, Dict, Any, Optional
import chess

class MoveSelector(ABC):
    """Abstract base class for move selection strategies."""

    @abstractmethod
    def select_move(self, moves_data: List[Dict[str, Any]], board: chess.Board, my_color: chess.Color) -> Optional[Dict[str, Any]]:
        """Selects a move based on a specific strategy."""
        pass

class MostPopularMoveSelector(MoveSelector):
    """Selects the move that has been played the most number of times."""

    def select_move(self, moves_data: List[Dict[str, Any]], board: chess.Board, my_color: chess.Color) -> Optional[Dict[str, Any]]:
        if not moves_data:
            return None
        # The API already returns moves sorted by popularity, so we just pick the first one.
        return moves_data[0]

class HighestWinRateMoveSelector(MoveSelector):
    """
    Selects the move with the highest win rate for `my_color`.
    A minimum number of games is required to consider a move.
    """

    def __init__(self, min_games: int = 50):
        self.min_games = min_games
        print(f"[INFO] HighestWinRateSelector initialized with min_games={self.min_games}")

    def select_move(self, moves_data: List[Dict[str, Any]], board: chess.Board, my_color: chess.Color) -> Optional[Dict[str, Any]]:
        best_move = None
        highest_win_rate = -1.0

        for move in moves_data:
            total_games = move['white'] + move['black'] + move['draws']

            if total_games < self.min_games:
                continue  # Skip moves with insufficient data

            wins = move['white'] if my_color == chess.WHITE else move['black']
            win_rate = wins / total_games

            if win_rate > highest_win_rate:
                highest_win_rate = win_rate
                best_move = move

        if best_move:
            print(f"    [!] Selected move {best_move['san']} with win rate: {highest_win_rate:.2%}")
        else:
            # Fallback to most popular if no moves meet the min_games criterion
            print(f"    [!] No moves met min_games={self.min_games}. Falling back to most popular move.")
            return MostPopularMoveSelector().select_move(moves_data, board, my_color)

        return best_move