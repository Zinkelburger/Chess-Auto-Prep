import sys
import io
import os
from typing import List, Dict, Tuple
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout,
                              QHBoxLayout, QSplitter, QListWidget, QListWidgetItem,
                              QLabel, QPushButton, QTextEdit, QProgressBar, QMenuBar,
                              QFileDialog, QMessageBox, QInputDialog, QTabWidget)
from PySide6.QtCore import Qt, QThread, Signal
from PySide6.QtGui import QFont, QAction, QPainter, QBrush, QColor, QPen, QPixmap
try:
    from PySide6.QtSvg import QSvgRenderer
    SVG_AVAILABLE = True
except ImportError:
    SVG_AVAILABLE = False
    print("SVG support not available")

import chess
import chess.pgn


class SimpleChessBoard(QWidget):
    def __init__(self):
        super().__init__()
        self.board = chess.Board()
        self.setMinimumSize(400, 400)
        self.piece_images = {}
        self.use_unicode_pieces = False
        self.load_piece_images()

    def load_piece_images(self):
        """Load piece images from SVG files"""
        piece_files = {
            (chess.WHITE, chess.PAWN): 'pieces/wP.svg',
            (chess.WHITE, chess.ROOK): 'pieces/wR.svg',
            (chess.WHITE, chess.KNIGHT): 'pieces/wN.svg',
            (chess.WHITE, chess.BISHOP): 'pieces/wB.svg',
            (chess.WHITE, chess.QUEEN): 'pieces/wQ.svg',
            (chess.WHITE, chess.KING): 'pieces/wK.svg',
            (chess.BLACK, chess.PAWN): 'pieces/bP.svg',
            (chess.BLACK, chess.ROOK): 'pieces/bR.svg',
            (chess.BLACK, chess.KNIGHT): 'pieces/bN.svg',
            (chess.BLACK, chess.BISHOP): 'pieces/bB.svg',
            (chess.BLACK, chess.QUEEN): 'pieces/bQ.svg',
            (chess.BLACK, chess.KING): 'pieces/bK.svg',
        }

        print(f"SVG support available: {SVG_AVAILABLE}")
        print(f"Current directory: {os.getcwd()}")

        if not SVG_AVAILABLE:
            print("Cannot load SVG files - SVG support not available")
            return

        for (color, piece_type), filename in piece_files.items():
            print(f"Trying to load {filename}...")
            if os.path.exists(filename):
                try:
                    # Load SVG and render to QPixmap
                    renderer = QSvgRenderer(filename)
                    if renderer.isValid():
                        pixmap = QPixmap(80, 80)  # Fixed size for pieces
                        pixmap.fill(Qt.transparent)
                        painter = QPainter(pixmap)
                        renderer.render(painter)
                        painter.end()
                        self.piece_images[(color, piece_type)] = pixmap
                        print(f"Successfully loaded {filename}")
                    else:
                        print(f"Invalid SVG file: {filename}")
                except Exception as e:
                    print(f"Error loading {filename}: {e}")
            else:
                print(f"File not found: {filename}")

        print(f"Loaded {len(self.piece_images)} piece images")

    def set_board(self, board):
        self.board = board
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)

        # Calculate square size
        size = min(self.width(), self.height())
        square_size = size // 8

        # Draw board
        for row in range(8):
            for col in range(8):
                x = col * square_size
                y = row * square_size

                # Alternate colors
                if (row + col) % 2 == 0:
                    painter.fillRect(x, y, square_size, square_size, QColor(240, 217, 181))
                else:
                    painter.fillRect(x, y, square_size, square_size, QColor(181, 136, 99))

                # Draw piece
                square = chess.square(col, 7-row)
                piece = self.board.piece_at(square)
                if piece:
                    piece_key = (piece.color, piece.piece_type)
                    if piece_key in self.piece_images:
                        # Use piece images
                        piece_pixmap = self.piece_images[piece_key]
                        scaled_pixmap = piece_pixmap.scaled(
                            square_size - 4, square_size - 4,
                            Qt.KeepAspectRatio, Qt.SmoothTransformation
                        )
                        piece_x = x + (square_size - scaled_pixmap.width()) // 2
                        piece_y = y + (square_size - scaled_pixmap.height()) // 2
                        painter.drawPixmap(piece_x, piece_y, scaled_pixmap)
                    else:
                        # Force the images to work - no text fallback!
                        print(f"Missing piece image for {piece_key}")
                        # Draw a colored rectangle as placeholder so we know pieces are there
                        if piece.color == chess.WHITE:
                            painter.fillRect(x + 5, y + 5, square_size - 10, square_size - 10, QColor(255, 255, 255))
                        else:
                            painter.fillRect(x + 5, y + 5, square_size - 10, square_size - 10, QColor(100, 100, 100))

from fen_map_builder import FenMapBuilder
from game_downloader import download_games_for_last_two_months, _get_cache_dir
from move_database import MoveDatabase
from game_navigator import GameNavigator
import json


class GameAnalysisThread(QThread):
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


class PositionLoadThread(QThread):
    """Background thread for loading position data from games"""
    finished = Signal(str, object)  # (fen, PositionData)
    error = Signal(str)

    def __init__(self, move_db: MoveDatabase, fen: str):
        super().__init__()
        self.move_db = move_db
        self.fen = fen

    def run(self):
        try:
            position_data = self.move_db.load_position(self.fen)
            self.finished.emit(self.fen, position_data)
        except Exception as e:
            self.error.emit(f"Error loading position: {str(e)}")


class ChessPrepGUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Chess Auto Prep - Opening Explorer")
        self.setGeometry(100, 100, 1400, 800)

        # Core data structures
        self.fen_builder = None
        self.move_db = MoveDatabase()
        self.game_navigator = GameNavigator()

        # State
        self.current_fen = None  # Currently displayed position
        self.position_load_thread = None
        self.analysis_thread = None
        self.active_threads = []  # Keep track of all active threads

        # Setup callbacks
        self.game_navigator.set_on_position_changed(self._on_position_changed)

        self.setup_ui()
        self.setup_menu()

    def setup_menu(self):
        menubar = self.menuBar()

        # File menu
        file_menu = menubar.addMenu("File")

        load_action = QAction("Load PGNs", self)
        load_action.triggered.connect(self.load_pgns)
        file_menu.addAction(load_action)

        download_action = QAction("Download from Chess.com", self)
        download_action.triggered.connect(self.download_games)
        file_menu.addAction(download_action)

        load_cache_action = QAction("Load from Cache", self)
        load_cache_action.triggered.connect(self.load_from_cache)
        file_menu.addAction(load_cache_action)

    def setup_ui(self):
        central_widget = QWidget()
        self.setCentralWidget(central_widget)

        main_layout = QHBoxLayout(central_widget)

        # Create splitter for resizable sections
        splitter = QSplitter(Qt.Horizontal)
        main_layout.addWidget(splitter)

        # Left panel - Position list
        left_panel = QWidget()
        left_layout = QVBoxLayout(left_panel)

        self.positions_label = QLabel("Problematic Positions")
        self.positions_label.setFont(QFont("Arial", 12, QFont.Bold))
        left_layout.addWidget(self.positions_label)

        self.positions_list = QListWidget()
        self.positions_list.itemClicked.connect(self.position_selected)
        left_layout.addWidget(self.positions_list)

        # Progress bar for analysis
        self.progress_bar = QProgressBar()
        self.progress_bar.setVisible(False)
        left_layout.addWidget(self.progress_bar)

        splitter.addWidget(left_panel)

        # Middle panel - Chess board
        middle_panel = QWidget()
        middle_layout = QVBoxLayout(middle_panel)

        self.board_label = QLabel("Position Analysis")
        self.board_label.setFont(QFont("Arial", 12, QFont.Bold))
        middle_layout.addWidget(self.board_label)

        # Chess board widget
        self.board = SimpleChessBoard()
        self.board.setMinimumSize(400, 400)
        middle_layout.addWidget(self.board)

        # Game navigation
        nav_layout = QHBoxLayout()
        self.prev_button = QPushButton("← Previous Game")
        self.prev_button.clicked.connect(self.previous_game)
        self.prev_button.setEnabled(False)
        nav_layout.addWidget(self.prev_button)

        self.game_label = QLabel("No game selected")
        nav_layout.addWidget(self.game_label)

        self.next_button = QPushButton("Next Game →")
        self.next_button.clicked.connect(self.next_game)
        self.next_button.setEnabled(False)
        nav_layout.addWidget(self.next_button)

        middle_layout.addLayout(nav_layout)

        # Move navigation within a game
        move_nav_layout = QHBoxLayout()
        self.start_button = QPushButton("|◀ Start")
        self.start_button.clicked.connect(self.goto_start)
        self.start_button.setEnabled(False)
        move_nav_layout.addWidget(self.start_button)

        self.back_button = QPushButton("◀ Back")
        self.back_button.clicked.connect(self.move_back)
        self.back_button.setEnabled(False)
        move_nav_layout.addWidget(self.back_button)

        self.move_label = QLabel("Move 0")
        move_nav_layout.addWidget(self.move_label)

        self.forward_button = QPushButton("Forward ▶")
        self.forward_button.clicked.connect(self.move_forward)
        self.forward_button.setEnabled(False)
        move_nav_layout.addWidget(self.forward_button)

        self.end_button = QPushButton("End ▶|")
        self.end_button.clicked.connect(self.goto_end)
        self.end_button.setEnabled(False)
        move_nav_layout.addWidget(self.end_button)

        middle_layout.addLayout(move_nav_layout)

        splitter.addWidget(middle_panel)

        # Right panel - Game details and moves
        right_panel = QWidget()
        right_layout = QVBoxLayout(right_panel)

        # Tabs for different views
        self.tab_widget = QTabWidget()

        # Move tree tab - shows all moves from current position with stats
        move_tree_widget = QWidget()
        move_tree_layout = QVBoxLayout(move_tree_widget)

        move_tree_label = QLabel("Moves from this position:")
        move_tree_label.setFont(QFont("Arial", 10, QFont.Bold))
        move_tree_layout.addWidget(move_tree_label)

        self.move_tree = QListWidget()
        self.move_tree.itemClicked.connect(self.move_tree_item_clicked)
        move_tree_layout.addWidget(self.move_tree)

        self.tab_widget.addTab(move_tree_widget, "Move Explorer")

        # Game info tab
        game_info_widget = QWidget()
        game_info_layout = QVBoxLayout(game_info_widget)

        self.position_stats = QLabel("Select a position to see stats")
        self.position_stats.setFont(QFont("Arial", 10))
        self.position_stats.setWordWrap(True)
        game_info_layout.addWidget(self.position_stats)

        self.game_info = QTextEdit()
        self.game_info.setMaximumHeight(150)
        game_info_layout.addWidget(self.game_info)

        self.moves_text = QTextEdit()
        self.moves_text.setFont(QFont("Courier", 10))
        game_info_layout.addWidget(self.moves_text)

        self.tab_widget.addTab(game_info_widget, "Game Analysis")

        # Lichess stats tab
        lichess_widget = QWidget()
        lichess_layout = QVBoxLayout(lichess_widget)

        self.lichess_stats = QLabel("Lichess database stats will appear here")
        self.lichess_stats.setWordWrap(True)
        lichess_layout.addWidget(self.lichess_stats)

        self.tab_widget.addTab(lichess_widget, "Database Stats")

        right_layout.addWidget(self.tab_widget)

        splitter.addWidget(right_panel)

        # Set splitter proportions
        splitter.setSizes([300, 500, 400])

    def load_pgns(self):
        file_path, _ = QFileDialog.getOpenFileName(self, "Load PGN File", "", "PGN Files (*.pgn)")
        if file_path:
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

                self.analyze_games(pgns)

            except Exception as e:
                QMessageBox.critical(self, "Error", f"Failed to load PGN file: {str(e)}")

    def download_games(self):
        username, ok = QInputDialog.getText(self, "Username", "Enter Chess.com username:")
        if not ok or not username:
            return

        # Ask for color preference
        items = ["White", "Black"]
        color, ok = QInputDialog.getItem(self, "Color", "Analyze games as:", items, 0, False)
        if not ok:
            return

        user_is_white = (color == "White")
        user_color = "white" if user_is_white else "black"

        try:
            self.progress_bar.setVisible(True)
            self.progress_bar.setValue(0)

            # Download games (this could be made async too)
            pgns = download_games_for_last_two_months(username, user_color=user_color)

            if not pgns:
                QMessageBox.information(self, "No Games", "No games found for the specified criteria.")
                self.progress_bar.setVisible(False)
                return

            self.analyze_games(pgns, username, user_is_white)

        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to download games: {str(e)}")
            self.progress_bar.setVisible(False)

    def load_from_cache(self):
        """Load games from cache directory"""
        cache_dir = _get_cache_dir()
        cache_files = [f for f in os.listdir(cache_dir) if f.endswith('.json')]

        if not cache_files:
            QMessageBox.information(self, "No Cache", "No cached games found.")
            return

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

        # Let user select which cache to load
        if not cache_info:
            QMessageBox.information(self, "No Cache", "No valid cached games found.")
            return

        items = [f"{name} ({count} games, {timestamp})" for name, count, timestamp in cache_info]
        item, ok = QInputDialog.getItem(self, "Select Cache", "Choose cached games to load:", items, 0, False)

        if not ok:
            return

        # Parse the selected item
        selected_index = items.index(item)
        cache_file, game_count, timestamp = cache_info[selected_index]

        # Extract username and color from filename (format: username_color.json)
        filename_parts = cache_file.replace('.json', '').split('_')
        if len(filename_parts) >= 2:
            username = '_'.join(filename_parts[:-1])
            color = filename_parts[-1]
        else:
            QMessageBox.critical(self, "Error", "Invalid cache file format.")
            return

        # Ask for color confirmation
        items = ["White", "Black"]
        default_color = 0 if color == "white" else 1
        color_choice, ok = QInputDialog.getItem(self, "Color", "Analyze games as:", items, default_color, False)
        if not ok:
            return

        user_is_white = (color_choice == "White")

        try:
            # Load games from cache
            with open(os.path.join(cache_dir, cache_file), "r") as f:
                cache_data = json.load(f)
            pgns = cache_data.get("games", [])

            if not pgns:
                QMessageBox.information(self, "No Games", "Cache file contains no games.")
                return

            self.analyze_games(pgns, username, user_is_white)

        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to load cache: {str(e)}")

    def analyze_games(self, pgns: List[str], username: str = None, user_is_white: bool = True):
        if not username:
            username, ok = QInputDialog.getText(self, "Username", "Enter your username:")
            if not ok or not username:
                return

        # Setup move database with games
        self.move_db.set_games(pgns, username, user_is_white)

        # Run analysis thread for FEN stats
        self.analysis_thread = GameAnalysisThread(pgns, username, user_is_white)
        self.analysis_thread.progress.connect(self.progress_bar.setValue)
        self.analysis_thread.finished.connect(self.analysis_finished)
        self.analysis_thread.finished.connect(lambda: self._thread_finished(self.analysis_thread))
        self.active_threads.append(self.analysis_thread)

        self.progress_bar.setVisible(True)
        self.analysis_thread.start()

    def analysis_finished(self, fen_builder: FenMapBuilder):
        self.fen_builder = fen_builder
        self.progress_bar.setVisible(False)
        self.populate_positions_list()

    def populate_positions_list(self):
        self.positions_list.clear()

        if not self.fen_builder:
            return

        # Get worst performing positions
        qualifying_positions = [
            (fen, stats) for fen, stats in self.fen_builder.fen_map.items()
            if stats.games >= 4
        ]

        if not qualifying_positions:
            return

        # Calculate performance and sort
        position_analysis = []
        for fen, stats in qualifying_positions:
            win_rate = (stats.wins + 0.5 * stats.draws) / stats.games
            position_analysis.append((fen, stats, win_rate))

        position_analysis.sort(key=lambda x: x[2])  # Sort by win rate (worst first)

        # Add to list widget
        for i, (fen, stats, win_rate) in enumerate(position_analysis[:20]):  # Show top 20
            item_text = f"{i+1}. {win_rate:.1%} ({stats.wins}-{stats.losses}-{stats.draws} in {stats.games} games)"
            item = QListWidgetItem(item_text)
            item.setData(Qt.UserRole, (fen, stats))  # Store FEN and stats
            self.positions_list.addItem(item)

    def position_selected(self, item):
        fen, stats = item.data(Qt.UserRole)
        self.current_fen = fen

        # Update board immediately
        try:
            board = chess.Board(fen)
            self.board.set_board(board)
        except:
            pass

        # Update position stats
        win_rate = (stats.wins + 0.5 * stats.draws) / stats.games
        stats_text = f"""Position Performance:
Win Rate: {win_rate:.1%}
Record: {stats.wins}-{stats.losses}-{stats.draws} in {stats.games} games

FEN: {fen}

Loading games..."""

        self.position_stats.setText(stats_text)

        # Clear move tree and show loading
        self.move_tree.clear()
        self.move_tree.addItem("Loading position data...")

        # Load games in background
        self.load_position_async(fen, stats)

    def load_position_async(self, fen: str, stats):
        """Load position data in background thread"""
        # Cancel any existing thread
        if self.position_load_thread and self.position_load_thread.isRunning():
            self.position_load_thread.wait()

        # Start new thread
        self.position_load_thread = PositionLoadThread(self.move_db, fen)
        self.position_load_thread.finished.connect(lambda f, pd: self.on_position_loaded(f, pd, stats))
        self.position_load_thread.error.connect(self.on_position_load_error)
        self.position_load_thread.finished.connect(lambda: self._thread_finished(self.position_load_thread))
        self.active_threads.append(self.position_load_thread)
        self.position_load_thread.start()

    def on_position_loaded(self, fen: str, position_data, stats):
        """Called when position data is loaded"""
        # Update position stats with game count
        win_rate = (stats.wins + 0.5 * stats.draws) / stats.games
        stats_text = f"""Position Performance:
Win Rate: {win_rate:.1%}
Record: {stats.wins}-{stats.losses}-{stats.draws} in {stats.games} games

FEN: {fen}

Games with this position: {len(position_data.games)}"""

        self.position_stats.setText(stats_text)

        # Load games into navigator
        self.game_navigator.load_games(position_data.games)

        # Update navigation UI
        self.update_game_navigation()
        self.update_move_navigation()

        # Load current game if any
        if position_data.games:
            self.load_current_game()

        # Build and display move tree
        self.build_move_tree_from_data(position_data)

    def on_position_load_error(self, error_msg: str):
        """Called when position loading fails"""
        QMessageBox.warning(self, "Load Error", error_msg)
        self.move_tree.clear()

    def build_move_tree_from_data(self, position_data):
        """Build move tree from loaded position data"""
        self.move_tree.clear()

        if not position_data.move_stats:
            self.move_tree.addItem("No moves from this position")
            return

        # Get sorted moves from position data
        sorted_moves = sorted(
            position_data.move_stats.values(),
            key=lambda m: m.win_rate,
            reverse=True
        )

        # Display in the move tree
        for move_stat in sorted_moves:
            item_text = f"{move_stat.move_san}: {move_stat.win_rate:.1%} ({move_stat.wins}-{move_stat.losses}-{move_stat.draws} in {move_stat.games})"
            item = QListWidgetItem(item_text)
            item.setData(Qt.UserRole, move_stat.move)
            self.move_tree.addItem(item)

    def update_game_navigation(self):
        if not self.game_navigator.has_games():
            self.game_label.setText("No games found")
            self.prev_button.setEnabled(False)
            self.next_button.setEnabled(False)
        else:
            total_games = len(self.game_navigator.games)
            self.game_label.setText(f"Game {self.game_navigator.current_game_index + 1} of {total_games}")
            self.prev_button.setEnabled(self.game_navigator.can_previous_game())
            self.next_button.setEnabled(self.game_navigator.can_next_game())

    def previous_game(self):
        if self.game_navigator.previous_game():
            self.load_current_game()
            self.update_game_navigation()

    def next_game(self):
        if self.game_navigator.next_game():
            self.load_current_game()
            self.update_game_navigation()

    def load_current_game(self):
        game_info = self.game_navigator.get_current_game_info()
        if not game_info:
            return

        # Display game information
        info_text = f"""White: {game_info['white']}
Black: {game_info['black']}
Result: {game_info['result']}

Game URL: {game_info['url']}

Position reached at move {game_info['move_index'] // 2 + 1}"""

        self.game_info.setPlainText(info_text)

        # Display the moves
        move_text = self.game_navigator.format_game_moves()
        self.moves_text.setPlainText(move_text)

        # Update navigation
        self.update_move_navigation()

        # Board is already updated by navigator callback

    def update_move_navigation(self):
        """Update move navigation button states"""
        if not self.game_navigator.has_games():
            self.move_label.setText("Move 0")
            self.start_button.setEnabled(False)
            self.back_button.setEnabled(False)
            self.forward_button.setEnabled(False)
            self.end_button.setEnabled(False)
        else:
            move_num = self.game_navigator.get_move_number()
            self.move_label.setText(f"Move {move_num}")

            self.start_button.setEnabled(self.game_navigator.can_go_back())
            self.back_button.setEnabled(self.game_navigator.can_go_back())
            self.forward_button.setEnabled(self.game_navigator.can_go_forward())
            self.end_button.setEnabled(self.game_navigator.can_go_forward())

    def _on_position_changed(self, board: chess.Board):
        """Called by GameNavigator when position changes"""
        self.board.set_board(board)
        # Update move tree for new position
        fen = self.game_navigator.get_current_fen()
        # Only update move tree if we have position data cached
        if fen in self.move_db._position_cache and self.move_db._position_cache[fen].loaded:
            self.build_move_tree_from_data(self.move_db._position_cache[fen])

    def goto_start(self):
        """Go to the start of the game"""
        if self.game_navigator.goto_start():
            self.update_move_navigation()

    def move_back(self):
        """Go back one move"""
        if self.game_navigator.move_back():
            self.update_move_navigation()

    def move_forward(self):
        """Go forward one move"""
        if self.game_navigator.move_forward():
            self.update_move_navigation()

    def goto_end(self):
        """Go to the end of the game"""
        if self.game_navigator.goto_end():
            self.update_move_navigation()

    def move_tree_item_clicked(self, item):
        """Handle clicking on a move in the move tree"""
        move = item.data(Qt.UserRole)

        # Apply the move using navigator
        if self.game_navigator.make_move(move):
            # Load position data for new position if needed
            new_fen = self.game_navigator.get_current_fen()
            if new_fen not in self.move_db._position_cache or not self.move_db._position_cache[new_fen].loaded:
                # Load in background
                self.move_tree.clear()
                self.move_tree.addItem("Loading...")
                thread = PositionLoadThread(self.move_db, new_fen)
                thread.finished.connect(lambda f, pd: self.build_move_tree_from_data(pd))
                thread.finished.connect(lambda: self._thread_finished(thread))
                self.active_threads.append(thread)
                thread.start()

    def _thread_finished(self, thread):
        """Remove finished thread from active threads list"""
        if thread in self.active_threads:
            self.active_threads.remove(thread)

    def closeEvent(self, event):
        """Handle window close - wait for all threads to finish"""
        # Wait for all active threads to finish
        for thread in self.active_threads:
            if thread and thread.isRunning():
                thread.wait(1000)  # Wait up to 1 second per thread
        event.accept()

    def keyPressEvent(self, event):
        """Handle keyboard shortcuts"""
        key = event.key()

        # Arrow keys for move navigation
        if key == Qt.Key_Left:
            self.move_back()
        elif key == Qt.Key_Right:
            self.move_forward()
        elif key == Qt.Key_Up:
            self.previous_game()
        elif key == Qt.Key_Down:
            self.next_game()
        elif key == Qt.Key_Home:
            self.goto_start()
        elif key == Qt.Key_End:
            self.goto_end()
        else:
            super().keyPressEvent(event)


def main():
    app = QApplication(sys.argv)
    window = ChessPrepGUI()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()