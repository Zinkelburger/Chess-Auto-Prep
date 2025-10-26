"""
Core data models for chess analysis.

Provides clean, type-safe data structures for positions, games, and analysis results.
"""
from dataclasses import dataclass, field
from typing import List, Dict, Optional
from pathlib import Path
import chess
import chess.pgn


@dataclass
class PositionStats:
    """Statistics for a chess position (FEN)."""
    fen: str
    games: int = 0
    wins: int = 0
    losses: int = 0
    draws: int = 0
    game_urls: List[str] = field(default_factory=list)

    @property
    def win_rate(self) -> float:
        """Calculate win rate (0.0 to 1.0)."""
        if self.games == 0:
            return 0.0
        return (self.wins + 0.5 * self.draws) / self.games

    @property
    def win_rate_percent(self) -> float:
        """Win rate as percentage."""
        return self.win_rate * 100


@dataclass
class GameInfo:
    """Information about a chess game."""
    pgn_path: Optional[Path] = None
    pgn_text: Optional[str] = None
    white: str = ""
    black: str = ""
    result: str = ""
    date: str = ""
    site: str = ""
    event: str = ""

    def __post_init__(self):
        """Parse PGN if provided."""
        if self.pgn_text and not self.white:
            self._parse_from_pgn()

    def _parse_from_pgn(self):
        """Extract headers from PGN text."""
        if not self.pgn_text:
            return

        import io
        try:
            game = chess.pgn.read_game(io.StringIO(self.pgn_text))
            if game:
                self.white = game.headers.get("White", "")
                self.black = game.headers.get("Black", "")
                self.result = game.headers.get("Result", "")
                self.date = game.headers.get("Date", "")
                self.site = game.headers.get("Site", "")
                self.event = game.headers.get("Event", "")
        except Exception:
            pass

    @property
    def title(self) -> str:
        """Human-readable game title."""
        if self.white and self.black:
            return f"{self.white} vs {self.black}"
        elif self.event:
            return self.event
        elif self.site:
            return self.site
        return "Unknown Game"

    @property
    def subtitle(self) -> str:
        """Secondary information about the game."""
        parts = []
        if self.date:
            parts.append(self.date)
        if self.result:
            parts.append(self.result)
        return " • ".join(parts) if parts else ""


@dataclass
class PositionAnalysis:
    """
    Complete analysis of positions from games.

    Maintains mappings between positions, statistics, and games.
    """
    position_stats: Dict[str, PositionStats] = field(default_factory=dict)
    games: List[GameInfo] = field(default_factory=list)

    # Mappings
    fen_to_game_indices: Dict[str, List[int]] = field(default_factory=dict)

    def add_position_stats(self, stats: PositionStats):
        """Add or update position statistics."""
        self.position_stats[stats.fen] = stats

    def add_game(self, game: GameInfo) -> int:
        """Add a game and return its index."""
        index = len(self.games)
        self.games.append(game)
        return index

    def link_fen_to_game(self, fen: str, game_index: int):
        """Create a mapping from FEN to game."""
        if fen not in self.fen_to_game_indices:
            self.fen_to_game_indices[fen] = []
        if game_index not in self.fen_to_game_indices[fen]:
            self.fen_to_game_indices[fen].append(game_index)

    def get_games_for_fen(self, fen: str) -> List[GameInfo]:
        """Get all games containing a specific position."""
        indices = self.fen_to_game_indices.get(fen, [])
        return [self.games[i] for i in indices if i < len(self.games)]

    def get_sorted_positions(self,
                            min_games: int = 3,
                            sort_by: str = 'win_rate') -> List[PositionStats]:
        """
        Get positions sorted by various criteria.

        Args:
            min_games: Minimum games for a position to be included
            sort_by: 'win_rate' (ascending), 'games' (descending), 'losses' (descending)
        """
        filtered = [
            stats for stats in self.position_stats.values()
            if stats.games >= min_games
        ]

        if sort_by == 'win_rate':
            return sorted(filtered, key=lambda s: s.win_rate)
        elif sort_by == 'games':
            return sorted(filtered, key=lambda s: s.games, reverse=True)
        elif sort_by == 'losses':
            return sorted(filtered, key=lambda s: s.losses, reverse=True)

        return filtered

    @classmethod
    def from_fen_map_builder(cls, fen_builder, pgn_list: List[str]) -> 'PositionAnalysis':
        """
        Create PositionAnalysis from FenMapBuilder results.

        Args:
            fen_builder: FenMapBuilder instance with analyzed data
            pgn_list: List of PGN strings for the games
        """
        analysis = cls()

        # Add all position stats
        for fen, node in fen_builder.fen_map.items():
            stats = PositionStats(
                fen=fen,
                games=node.games,
                wins=node.wins,
                losses=node.losses,
                draws=node.draws,
                game_urls=node.game_urls.copy()
            )
            analysis.add_position_stats(stats)

        # Add games and create mappings
        import io
        for pgn_text in pgn_list:
            game_info = GameInfo(pgn_text=pgn_text)
            game_index = analysis.add_game(game_info)

            # Parse game to find which FENs it contains
            try:
                game = chess.pgn.read_game(io.StringIO(pgn_text))
                if game:
                    board = game.board()
                    seen_fens = set()

                    for move in game.mainline_moves():
                        board.push(move)
                        fen_key = cls._fen_key_from_board(board)

                        if fen_key in analysis.position_stats and fen_key not in seen_fens:
                            analysis.link_fen_to_game(fen_key, game_index)
                            seen_fens.add(fen_key)
            except Exception:
                continue

        return analysis

    @staticmethod
    def _fen_key_from_board(board) -> str:
        """Convert board to shortened FEN key (without move counters)."""
        fen_full = board.fen()
        piece_placement, side_to_move, castling, en_passant, *_ = fen_full.split()
        return f"{piece_placement} {side_to_move} {castling} {en_passant}"
