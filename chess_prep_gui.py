import sys
import io
from typing import List, Dict, Tuple
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout,
                              QHBoxLayout, QSplitter, QListWidget, QListWidgetItem,
                              QLabel, QPushButton, QTextEdit, QProgressBar, QMenuBar,
                              QFileDialog, QMessageBox, QInputDialog, QTabWidget)
from PySide6.QtCore import Qt, QThread, Signal
from PySide6.QtGui import QFont, QAction, QPainter, QBrush, QColor, QPen

import chess
import chess.pgn


class SimpleChessBoard(QWidget):
    def __init__(self):
        super().__init__()
        self.board = chess.Board()
        self.setMinimumSize(400, 400)

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
                    # Simple text representation of pieces
                    piece_char = piece.unicode_symbol()
                    painter.setPen(QPen(QColor(0, 0, 0)))
                    painter.setFont(QFont("Arial", square_size // 2))
                    painter.drawText(x + square_size//4, y + 3*square_size//4, piece_char)

from fen_map_builder import FenMapBuilder
from game_downloader import download_games_for_last_two_months


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


class ChessPrepGUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Chess Auto Prep - Opening Explorer")
        self.setGeometry(100, 100, 1400, 800)

        self.fen_builder = None
        self.current_games = []  # Store games for current position
        self.current_game_index = 0

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

        splitter.addWidget(middle_panel)

        # Right panel - Game details and moves
        right_panel = QWidget()
        right_layout = QVBoxLayout(right_panel)

        # Tabs for different views
        self.tab_widget = QTabWidget()

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

    def analyze_games(self, pgns: List[str], username: str = None, user_is_white: bool = True):
        if not username:
            username, ok = QInputDialog.getText(self, "Username", "Enter your username:")
            if not ok or not username:
                return

        self.analysis_thread = GameAnalysisThread(pgns, username, user_is_white)
        self.analysis_thread.progress.connect(self.progress_bar.setValue)
        self.analysis_thread.finished.connect(self.analysis_finished)

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

        # Update board
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

Games with this position: {len(stats.game_urls)}"""

        self.position_stats.setText(stats_text)

        # Load games for this position (we'll need to implement this)
        self.load_games_for_position(fen)

    def load_games_for_position(self, fen: str):
        if not self.fen_builder:
            return

        # Find games that contain this position
        self.current_games = []
        stats = self.fen_builder.fen_map[fen]

        # We need to search through our original PGNs to find games with this position
        # For now, we'll create placeholder games based on the game URLs
        for i, url in enumerate(stats.game_urls):
            # Create a mock game object with the URL for display
            game_info = {
                'url': url,
                'index': i,
                'fen': fen
            }
            self.current_games.append(game_info)

        self.current_game_index = 0
        self.update_game_navigation()

        if self.current_games:
            self.load_current_game()

    def update_game_navigation(self):
        total_games = len(self.current_games)
        if total_games == 0:
            self.game_label.setText("No games found")
            self.prev_button.setEnabled(False)
            self.next_button.setEnabled(False)
        else:
            self.game_label.setText(f"Game {self.current_game_index + 1} of {total_games}")
            self.prev_button.setEnabled(self.current_game_index > 0)
            self.next_button.setEnabled(self.current_game_index < total_games - 1)

    def previous_game(self):
        if self.current_game_index > 0:
            self.current_game_index -= 1
            self.load_current_game()
            self.update_game_navigation()

    def next_game(self):
        if self.current_game_index < len(self.current_games) - 1:
            self.current_game_index += 1
            self.load_current_game()
            self.update_game_navigation()

    def load_current_game(self):
        if not self.current_games or self.current_game_index >= len(self.current_games):
            return

        game_info = self.current_games[self.current_game_index]

        # Display game information
        info_text = f"""Game URL: {game_info['url']}

Position FEN: {game_info['fen']}

Click the URL above to view the game on Chess.com"""

        self.game_info.setPlainText(info_text)

        # For moves, we'd need to load the actual PGN
        # For now, show a placeholder
        self.moves_text.setPlainText("PGN moves would be displayed here.\nTo implement: store PGNs and search for games containing this position.")

        # Update the board to show the position
        try:
            board = chess.Board(game_info['fen'])
            self.board.set_board(board)
        except:
            pass


def main():
    app = QApplication(sys.argv)
    window = ChessPrepGUI()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()