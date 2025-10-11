"""
Main application controller.
"""
import os
import json
from typing import List, Optional
from PySide6.QtWidgets import QMessageBox, QInputDialog, QFileDialog
from PySide6.QtCore import QObject, Signal

import chess
from move_database import MoveDatabase
from game_navigator import GameNavigator
from fen_map_builder import FenMapBuilder
from game_downloader import download_games_for_last_two_months, _get_cache_dir
from services.game_analysis import GameAnalysisService
from ui.position_analyzer import PositionLoadThread


class MainController(QObject):
    """Main application controller managing business logic."""

    position_selected = Signal(str, object)  # fen, stats
    position_loaded = Signal(str, object, object)  # fen, position_data, stats
    analysis_finished = Signal(object)  # fen_builder
    progress_updated = Signal(int)
    board_updated = Signal(object)  # chess.Board

    def __init__(self):
        super().__init__()
        self.fen_builder: Optional[FenMapBuilder] = None
        self.move_db = MoveDatabase()
        self.game_navigator = GameNavigator()
        self.game_analysis_service = GameAnalysisService()
        self.active_threads = []

        # Setup callbacks
        self.game_navigator.set_on_position_changed(self._on_position_changed)

    def load_pgns_from_file(self, parent_widget) -> bool:
        """Load PGN games from file."""
        file_path, _ = QFileDialog.getOpenFileName(parent_widget, "Load PGN File", "", "PGN Files (*.pgn)")
        if not file_path:
            return False

        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read().strip()

            # Split into individual games
            if "[Event " in content:
                pgns = content.split("\n\n[Event ")
                if len(pgns) > 1:
                    pgns = [pgns[0]] + ["[Event " + chunk for chunk in pgns[1:]]
            else:
                pgns = [content]

            self._analyze_games(pgns)
            return True

        except Exception as e:
            QMessageBox.critical(parent_widget, "Error", f"Failed to load PGN file: {str(e)}")
            return False

    def download_games_from_chess_com(self, parent_widget) -> bool:
        """Download games from Chess.com."""
        username, ok = QInputDialog.getText(parent_widget, "Username", "Enter Chess.com username:")
        if not ok or not username:
            return False

        # Ask for color preference
        items = ["White", "Black"]
        color, ok = QInputDialog.getItem(parent_widget, "Color", "Analyze games as:", items, 0, False)
        if not ok:
            return False

        user_is_white = (color == "White")
        user_color = "white" if user_is_white else "black"

        try:
            # Download games
            pgns = download_games_for_last_two_months(username, user_color=user_color)

            if not pgns:
                QMessageBox.information(parent_widget, "No Games", "No games found for the specified criteria.")
                return False

            self._analyze_games(pgns, username, user_is_white)
            return True

        except Exception as e:
            QMessageBox.critical(parent_widget, "Error", f"Failed to download games: {str(e)}")
            return False

    def load_from_cache(self, parent_widget) -> bool:
        """Load games from cache."""
        cache_dir = _get_cache_dir()
        cache_files = [f for f in os.listdir(cache_dir) if f.endswith('.json')]

        if not cache_files:
            QMessageBox.information(parent_widget, "No Cache", "No cached games found.")
            return False

        # Create a list of cache files with metadata
        cache_info = []
        for cache_file in sorted(cache_files):
            try:
                with open(os.path.join(cache_dir, cache_file), "r") as f:
                    cache_data = json.load(f)
                timestamp = cache_data.get("timestamp", "Unknown")
                game_count = len(cache_data.get("games", []))
                cache_info.append((cache_file, game_count, timestamp))
            except:
                continue

        if not cache_info:
            QMessageBox.information(parent_widget, "No Cache", "No valid cached games found.")
            return False

        items = [f"{name} ({count} games, {timestamp})" for name, count, timestamp in cache_info]
        item, ok = QInputDialog.getItem(parent_widget, "Select Cache", "Choose cached games to load:", items, 0, False)

        if not ok:
            return False

        # Parse the selected item
        selected_index = items.index(item)
        cache_file, game_count, timestamp = cache_info[selected_index]

        # Extract username and color from filename
        filename_parts = cache_file.replace('.json', '').split('_')
        if len(filename_parts) >= 2:
            username = '_'.join(filename_parts[:-1])
            color = filename_parts[-1]
        else:
            QMessageBox.critical(parent_widget, "Error", "Invalid cache file format.")
            return False

        # Ask for color confirmation
        items = ["White", "Black"]
        default_color = 0 if color == "white" else 1
        color_choice, ok = QInputDialog.getItem(parent_widget, "Color", "Analyze games as:", items, default_color, False)
        if not ok:
            return False

        user_is_white = (color_choice == "White")

        try:
            # Load games from cache
            with open(os.path.join(cache_dir, cache_file), "r") as f:
                cache_data = json.load(f)
            pgns = cache_data.get("games", [])

            if not pgns:
                QMessageBox.information(parent_widget, "No Games", "Cache file contains no games.")
                return False

            self._analyze_games(pgns, username, user_is_white)
            return True

        except Exception as e:
            QMessageBox.critical(parent_widget, "Error", f"Failed to load cache: {str(e)}")
            return False

    def handle_position_selected(self, item):
        """Handle position selection from the list."""
        fen, stats = item.data(1024)  # Qt.UserRole
        self.position_selected.emit(fen, stats)

        # Update board immediately
        try:
            board = chess.Board(fen)
            self.board_updated.emit(board)
        except:
            pass

        # Load games in background
        self._load_position_async(fen, stats)

    def handle_move_clicked(self, item):
        """Handle move selection from move explorer."""
        move = item.data(1024)  # Qt.UserRole

        # Apply the move using navigator
        if self.game_navigator.make_move(move):
            # Load position data for new position if needed
            new_fen = self.game_navigator.get_current_fen()
            if new_fen not in self.move_db._position_cache or not self.move_db._position_cache[new_fen].loaded:
                # Load in background
                thread = PositionLoadThread(self.move_db, new_fen)
                thread.finished.connect(lambda f, pd: self.position_loaded.emit(f, pd, None))
                thread.finished.connect(lambda: self._thread_finished(thread))
                self.active_threads.append(thread)
                thread.start()

    def cleanup(self):
        """Cleanup resources."""
        self.game_analysis_service.cleanup()
        # Wait for all active threads to finish
        for thread in self.active_threads:
            if thread and thread.isRunning():
                thread.wait(1000)

    def _analyze_games(self, pgns: List[str], username: str = None, user_is_white: bool = True):
        """Analyze games with given parameters."""
        if not username:
            username, ok = QInputDialog.getText(None, "Username", "Enter your username:")
            if not ok or not username:
                return

        # Setup move database with games
        self.move_db.set_games(pgns, username, user_is_white)

        # Run analysis thread for FEN stats
        analysis_thread = self.game_analysis_service.analyze_games(pgns, username, user_is_white)
        analysis_thread.progress.connect(self.progress_updated.emit)
        analysis_thread.finished.connect(self._on_analysis_finished)
        analysis_thread.finished.connect(lambda: self._thread_finished(analysis_thread))
        self.active_threads.append(analysis_thread)
        analysis_thread.start()

    def _on_analysis_finished(self, fen_builder: FenMapBuilder):
        """Handle analysis completion."""
        self.fen_builder = fen_builder
        self.analysis_finished.emit(fen_builder)

    def _load_position_async(self, fen: str, stats):
        """Load position data in background thread."""
        # Cancel any existing thread for this position
        thread = PositionLoadThread(self.move_db, fen)
        thread.finished.connect(lambda f, pd: self.position_loaded.emit(f, pd, stats))
        thread.finished.connect(lambda: self._thread_finished(thread))
        self.active_threads.append(thread)
        thread.start()

    def _on_position_changed(self, board: chess.Board):
        """Called by GameNavigator when position changes."""
        self.board_updated.emit(board)

    def _thread_finished(self, thread):
        """Remove finished thread from active threads list."""
        if thread in self.active_threads:
            self.active_threads.remove(thread)