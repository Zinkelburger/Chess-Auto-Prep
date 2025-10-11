"""
Game analysis service for processing chess games.
"""
import io
from typing import List
from PySide6.QtCore import QThread, Signal

import chess
import chess.pgn
from fen_map_builder import FenMapBuilder


class GameAnalysisThread(QThread):
    """Thread for analyzing games in the background."""
    progress = Signal(int)
    finished = Signal(object)  # FenMapBuilder object

    def __init__(self, pgns: List[str], username: str, user_is_white: bool):
        super().__init__()
        self.pgns = pgns
        self.username = username
        self.user_is_white = user_is_white

    def run(self):
        fen_builder = FenMapBuilder()
        total_games = len(self.pgns)

        for i, pgn_text in enumerate(self.pgns):
            game = chess.pgn.read_game(io.StringIO(pgn_text))
            if game:
                final_result = game.headers.get("Result", "")
                game_user_white = (game.headers.get("White", "").lower() == self.username.lower())

                if self.user_is_white == game_user_white:
                    game_url = game.headers.get("Site", "")
                    fen_builder._update_fen_map_for_game(game, final_result, game_user_white, game_url)

            # Emit progress
            progress_percent = int((i + 1) / total_games * 100)
            self.progress.emit(progress_percent)

        self.finished.emit(fen_builder)


class GameAnalysisService:
    """Service for managing game analysis operations."""

    def __init__(self):
        self.current_thread = None

    def analyze_games(self, pgns: List[str], username: str, user_is_white: bool) -> GameAnalysisThread:
        """Start game analysis in background thread."""
        if self.current_thread and self.current_thread.isRunning():
            self.current_thread.wait()

        self.current_thread = GameAnalysisThread(pgns, username, user_is_white)
        return self.current_thread

    def cleanup(self):
        """Cleanup any running threads."""
        if self.current_thread and self.current_thread.isRunning():
            self.current_thread.wait(1000)