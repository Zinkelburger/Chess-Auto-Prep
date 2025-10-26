"""
Game navigation for stepping through chess moves.
"""
import chess
import chess.pgn
from typing import List, Optional, Callable


class GameNavigator:
    """
    Manages navigation through a chess game's moves.
    Maintains board state and current position.
    """

    def __init__(self):
        self.games: List[dict] = []
        self.current_game_index: int = 0
        self.current_move_index: int = 0
        self.current_board: chess.Board = chess.Board()
        self.current_game_moves: List[chess.Move] = []
        self._on_position_changed: Optional[Callable[[chess.Board], None]] = None

    def set_on_position_changed(self, callback: Callable[[chess.Board], None]):
        """Set callback to be called when position changes"""
        self._on_position_changed = callback

    def load_games(self, games: List[dict]):
        """Load a list of games and reset to first game"""
        self.games = games
        self.current_game_index = 0
        if games:
            self._load_current_game()
        else:
            self.current_game_moves = []
            self.current_move_index = 0
            self.current_board = chess.Board()

    def _load_current_game(self):
        """Load moves from the current game"""
        if not self.games or self.current_game_index >= len(self.games):
            return

        game_info = self.games[self.current_game_index]
        game = game_info['game']
        self.current_game_moves = list(game.mainline_moves())

        # Set position to the stored move index (usually the problematic position)
        self.current_move_index = game_info.get('move_index', 0)
        self._update_board()

    def _update_board(self):
        """Update board to match current move index"""
        if not self.games or not self.current_game_moves:
            self.current_board = chess.Board()
            return

        game = self.games[self.current_game_index]['game']
        self.current_board = game.board()

        # Play moves up to current_move_index
        for i in range(min(self.current_move_index, len(self.current_game_moves))):
            self.current_board.push(self.current_game_moves[i])

        if self._on_position_changed:
            self._on_position_changed(self.current_board)

    def get_current_game_info(self) -> Optional[dict]:
        """Get current game information"""
        if not self.games or self.current_game_index >= len(self.games):
            return None
        return self.games[self.current_game_index]

    def get_current_fen(self) -> str:
        """Get FEN of current position"""
        fen_full = self.current_board.fen()
        piece_placement, side_to_move, castling, en_passant, *_ = fen_full.split()
        return f"{piece_placement} {side_to_move} {castling} {en_passant}"

    # Game navigation
    def previous_game(self) -> bool:
        """Go to previous game. Returns True if successful."""
        if self.current_game_index > 0:
            self.current_game_index -= 1
            self._load_current_game()
            return True
        return False

    def next_game(self) -> bool:
        """Go to next game. Returns True if successful."""
        if self.current_game_index < len(self.games) - 1:
            self.current_game_index += 1
            self._load_current_game()
            return True
        return False

    # Move navigation
    def goto_start(self) -> bool:
        """Go to start of game. Returns True if position changed."""
        if self.current_move_index != 0:
            self.current_move_index = 0
            self._update_board()
            return True
        return False

    def move_back(self) -> bool:
        """Go back one move. Returns True if successful."""
        if self.current_move_index > 0:
            self.current_move_index -= 1
            self._update_board()
            return True
        return False

    def move_forward(self) -> bool:
        """Go forward one move. Returns True if successful."""
        if self.current_move_index < len(self.current_game_moves):
            self.current_move_index += 1
            self._update_board()
            return True
        return False

    def goto_end(self) -> bool:
        """Go to end of game. Returns True if position changed."""
        end_index = len(self.current_game_moves)
        if self.current_move_index != end_index:
            self.current_move_index = end_index
            self._update_board()
            return True
        return False

    def make_move(self, move: chess.Move) -> bool:
        """
        Make a move from current position.
        Updates board but doesn't follow game moves.
        Returns True if successful.
        """
        try:
            self.current_board.push(move)
            if self._on_position_changed:
                self._on_position_changed(self.current_board)
            return True
        except:
            return False

    # State queries
    def has_games(self) -> bool:
        """Check if any games are loaded"""
        return len(self.games) > 0

    def can_go_back(self) -> bool:
        """Check if we can go back a move"""
        return self.current_move_index > 0

    def can_go_forward(self) -> bool:
        """Check if we can go forward a move"""
        return self.current_move_index < len(self.current_game_moves)

    def can_previous_game(self) -> bool:
        """Check if we can go to previous game"""
        return self.current_game_index > 0

    def can_next_game(self) -> bool:
        """Check if we can go to next game"""
        return self.current_game_index < len(self.games) - 1

    def get_move_number(self) -> int:
        """Get current move number"""
        return self.current_move_index // 2 + 1

    def format_game_moves(self) -> str:
        """Format moves of current game as text"""
        if not self.games or self.current_game_index >= len(self.games):
            return ""

        game = self.games[self.current_game_index]['game']
        board = game.board()
        moves = []
        move_number = 1

        for move in game.mainline_moves():
            if board.turn == chess.WHITE:
                moves.append(f"{move_number}. {board.san(move)}")
            else:
                moves.append(f"{board.san(move)}")
                move_number += 1
            board.push(move)

        # Join moves in a readable format (5 move pairs per line)
        formatted = []
        for i in range(0, len(moves), 10):
            formatted.append(" ".join(moves[i:i+10]))

        return "\n".join(formatted)
