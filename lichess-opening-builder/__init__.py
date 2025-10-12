"""
Lichess Opening Builder

A chess repertoire builder that uses Lichess database statistics to create
personalized opening repertoires with different move selection algorithms.
"""

__version__ = "1.0.0"
__author__ = "Lichess Opening Builder"

from .move_selectors import MoveSelector, MostPopularMoveSelector, HighestWinRateMoveSelector
from .pgn_writer import PgnWriter
from .repertoire_builder import RepertoireBuilder

__all__ = [
    "MoveSelector",
    "MostPopularMoveSelector",
    "HighestWinRateMoveSelector",
    "PgnWriter",
    "RepertoireBuilder"
]