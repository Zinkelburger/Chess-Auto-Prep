"""
Move database for lazy loading and caching game positions and move statistics.
"""
import io
import chess
import chess.pgn
from typing import List, Dict, Optional, Tuple
from collections import defaultdict


class MoveStatistics:
    """Statistics for a single move from a position"""
    def __init__(self, move_san: str, move: chess.Move):
        self.move_san = move_san
        self.move = move
        self.wins = 0
        self.draws = 0
        self.losses = 0
        self.games = 0

    @property
    def win_rate(self) -> float:
        """Calculate win rate (0.0 to 1.0)"""
        if self.games == 0:
            return 0.0
        return (self.wins + 0.5 * self.draws) / self.games


class PositionData:
    """Cached data for a single position"""
    def __init__(self, fen: str):
        self.fen = fen
        self.games: List[dict] = []  # List of game info dicts
        self.move_stats: Dict[str, MoveStatistics] = {}  # move_san -> MoveStatistics
        self.loaded = False


class MoveDatabase:
    """
    Lazy-loading database of positions and moves from PGN games.
    Parses games on-demand to avoid UI freezing.
    """

    def __init__(self):
        self.pgns: List[str] = []
        self.username: str = ""
        self.user_is_white: bool = True
        self._position_cache: Dict[str, PositionData] = {}  # fen -> PositionData

    def set_games(self, pgns: List[str], username: str, user_is_white: bool):
        """Set the PGN games to analyze"""
        self.pgns = pgns
        self.username = username
        self.user_is_white = user_is_white
        self._position_cache.clear()

    @staticmethod
    def _fen_key_from_board(board: chess.Board) -> str:
        """Convert board to FEN key (without move counters)"""
        fen_full = board.fen()
        piece_placement, side_to_move, castling, en_passant, *_ = fen_full.split()
        return f"{piece_placement} {side_to_move} {castling} {en_passant}"

    def load_position(self, fen: str) -> PositionData:
        """
        Load all games and moves for a given position.
        Returns cached data if already loaded.
        """
        # Check cache first
        if fen in self._position_cache and self._position_cache[fen].loaded:
            return self._position_cache[fen]

        # Create new position data
        position_data = PositionData(fen)

        # Parse all games to find ones that reach this position
        for pgn_text in self.pgns:
            game = chess.pgn.read_game(io.StringIO(pgn_text))
            if not game:
                continue

            # Check if this game reaches the target FEN
            board = game.board()
            found_position = False
            move_index_at_position = 0

            for ply_index, move in enumerate(game.mainline_moves()):
                board.push(move)
                current_fen = self._fen_key_from_board(board)

                if current_fen == fen:
                    found_position = True
                    move_index_at_position = ply_index + 1
                    break

            if found_position:
                # Store game info
                game_info = {
                    'pgn_text': pgn_text,
                    'game': game,
                    'url': game.headers.get("Site", ""),
                    'fen': fen,
                    'move_index': move_index_at_position,
                    'result': game.headers.get("Result", ""),
                    'white': game.headers.get("White", ""),
                    'black': game.headers.get("Black", ""),
                }
                position_data.games.append(game_info)

                # Update move statistics
                self._update_move_stats_for_game(position_data, game, fen, board)

        position_data.loaded = True
        self._position_cache[fen] = position_data
        return position_data

    def _update_move_stats_for_game(self, position_data: PositionData,
                                     game: chess.pgn.Game, fen: str,
                                     board_at_position: chess.Board):
        """Update move statistics for a game that reaches the position"""
        result = game.headers.get("Result", "")
        game_user_white = (game.headers.get("White", "").lower() == self.username.lower())

        # Replay from start to find the position and get the next move
        board = game.board()
        moves_list = list(game.mainline_moves())

        for i, move in enumerate(moves_list):
            board.push(move)
            if self._fen_key_from_board(board) == fen:
                # Found the position - get the next move if it exists
                if i + 1 < len(moves_list):
                    next_move = moves_list[i + 1]
                    move_san = board.san(next_move)

                    # Get or create move stats
                    if move_san not in position_data.move_stats:
                        position_data.move_stats[move_san] = MoveStatistics(move_san, next_move)

                    stats = position_data.move_stats[move_san]
                    stats.games += 1

                    # Update W/L/D based on result from user's perspective
                    if result == "1-0":
                        if game_user_white:
                            stats.wins += 1
                        else:
                            stats.losses += 1
                    elif result == "0-1":
                        if game_user_white:
                            stats.losses += 1
                        else:
                            stats.wins += 1
                    elif result == "1/2-1/2":
                        stats.draws += 1

                break

    def get_sorted_moves(self, fen: str) -> List[MoveStatistics]:
        """Get moves from a position, sorted by win rate (best first)"""
        position_data = self.load_position(fen)
        moves = list(position_data.move_stats.values())
        moves.sort(key=lambda m: m.win_rate, reverse=True)
        return moves

    def get_games_for_position(self, fen: str) -> List[dict]:
        """Get all games that reach a given position"""
        position_data = self.load_position(fen)
        return position_data.games
