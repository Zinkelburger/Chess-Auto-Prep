"""
Move selection strategies for repertoire building.

Different strategies for selecting your moves in coverage mode.
"""

from abc import ABC, abstractmethod
from typing import List, Dict, Any, Optional

import chess


class MoveSelector(ABC):
    """Abstract base class for move selection strategies."""

    @abstractmethod
    def select_move(
        self,
        moves_data: List[Dict[str, Any]],
        board: chess.Board,
        my_color: chess.Color
    ) -> Optional[Dict[str, Any]]:
        """
        Select a move from the available options.

        Args:
            moves_data: List of move data from Lichess API
            board: Current board position
            my_color: Your color

        Returns:
            Selected move data, or None if no valid move
        """
        pass


class MostPopularMoveSelector(MoveSelector):
    """Selects the move that has been played the most."""

    def select_move(
        self,
        moves_data: List[Dict[str, Any]],
        board: chess.Board,
        my_color: chess.Color
    ) -> Optional[Dict[str, Any]]:
        if not moves_data:
            return None
        # API returns moves sorted by popularity
        return moves_data[0]


class HighestWinRateMoveSelector(MoveSelector):
    """
    Selects the move with the highest win rate.
    Requires a minimum number of games for statistical significance.
    """

    def __init__(self, min_games: int = 50):
        """
        Initialize selector.

        Args:
            min_games: Minimum games required to consider a move
        """
        self.min_games = min_games

    def select_move(
        self,
        moves_data: List[Dict[str, Any]],
        board: chess.Board,
        my_color: chess.Color
    ) -> Optional[Dict[str, Any]]:
        best_move = None
        highest_win_rate = -1.0

        for move in moves_data:
            total_games = move["white"] + move["black"] + move["draws"]

            if total_games < self.min_games:
                continue

            wins = move["white"] if my_color == chess.WHITE else move["black"]
            win_rate = wins / total_games

            if win_rate > highest_win_rate:
                highest_win_rate = win_rate
                best_move = move

        if best_move:
            print(f"    [WinRate] Selected {best_move['san']} ({highest_win_rate:.1%})")
            return best_move

        # Fallback to most popular if no moves meet min_games
        print(f"    [WinRate] No moves with {self.min_games}+ games, using most popular")
        return MostPopularMoveSelector().select_move(moves_data, board, my_color)


def create_selector(args) -> MoveSelector:
    """
    Factory function to create the appropriate move selector.

    Args:
        args: Parsed command-line arguments

    Returns:
        Configured move selector
    """
    if args.my_move_algo == "winrate":
        return HighestWinRateMoveSelector(min_games=args.winrate_min_games)
    return MostPopularMoveSelector()

