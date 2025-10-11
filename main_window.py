"""
Main application window.
"""
from PySide6.QtWidgets import (QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
                              QSplitter, QProgressBar, QMenuBar, QTextEdit, QTabWidget)
from PySide6.QtCore import Qt
from PySide6.QtGui import QFont, QAction

from ui.chess_board import ChessBoardWidget
from ui.position_analyzer import PositionListWidget, MoveExplorerWidget
from ui.navigation import GameNavigationWidget, MoveNavigationWidget
from controllers.main_controller import MainController


class ChessPrepMainWindow(QMainWindow):
    """Main application window."""

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Chess Auto Prep - Opening Explorer")
        self.setGeometry(100, 100, 1400, 800)

        # Initialize controller
        self.controller = MainController()

        # Initialize UI components
        self._setup_ui()
        self._setup_menu()
        self._connect_signals()

    def _setup_ui(self):
        """Setup the user interface."""
        central_widget = QWidget()
        self.setCentralWidget(central_widget)

        main_layout = QHBoxLayout(central_widget)

        # Create splitter for resizable sections
        splitter = QSplitter(Qt.Horizontal)
        main_layout.addWidget(splitter)

        # Left panel - Position list
        left_panel = self._create_left_panel()
        splitter.addWidget(left_panel)

        # Middle panel - Chess board and navigation
        middle_panel = self._create_middle_panel()
        splitter.addWidget(middle_panel)

        # Right panel - Move explorer and game info
        right_panel = self._create_right_panel()
        splitter.addWidget(right_panel)

        # Set splitter proportions
        splitter.setSizes([300, 500, 400])

    def _create_left_panel(self) -> QWidget:
        """Create the left panel with position list."""
        panel = QWidget()
        layout = QVBoxLayout(panel)

        # Position list
        self.position_list = PositionListWidget()
        layout.addWidget(self.position_list)

        # Progress bar for analysis
        self.progress_bar = QProgressBar()
        self.progress_bar.setVisible(False)
        layout.addWidget(self.progress_bar)

        return panel

    def _create_middle_panel(self) -> QWidget:
        """Create the middle panel with chess board and navigation."""
        panel = QWidget()
        layout = QVBoxLayout(panel)

        # Board label
        board_label = QWidget()
        board_label_layout = QVBoxLayout(board_label)
        board_label_layout.addWidget(self._create_label("Position Analysis"))
        layout.addWidget(board_label)

        # Chess board
        self.chess_board = ChessBoardWidget()
        layout.addWidget(self.chess_board)

        # Game navigation
        self.game_navigation = GameNavigationWidget(self.controller.game_navigator)
        layout.addWidget(self.game_navigation)

        # Move navigation
        self.move_navigation = MoveNavigationWidget(self.controller.game_navigator)
        layout.addWidget(self.move_navigation)

        return panel

    def _create_right_panel(self) -> QWidget:
        """Create the right panel with tabs."""
        panel = QWidget()
        layout = QVBoxLayout(panel)

        # Tabs for different views
        tab_widget = QTabWidget()

        # Move explorer tab
        self.move_explorer = MoveExplorerWidget()
        tab_widget.addTab(self.move_explorer, "Move Explorer")

        # Game info tab
        game_info_widget = self._create_game_info_tab()
        tab_widget.addTab(game_info_widget, "Game Analysis")

        layout.addWidget(tab_widget)
        return panel

    def _create_game_info_tab(self) -> QWidget:
        """Create the game info tab."""
        widget = QWidget()
        layout = QVBoxLayout(widget)

        self.position_stats = self._create_label("Select a position to see stats")
        self.position_stats.setWordWrap(True)
        layout.addWidget(self.position_stats)

        self.game_info = QTextEdit()
        self.game_info.setMaximumHeight(150)
        layout.addWidget(self.game_info)

        self.moves_text = QTextEdit()
        self.moves_text.setFont(QFont("Courier", 10))
        layout.addWidget(self.moves_text)

        return widget

    def _create_label(self, text: str):
        """Create a label with consistent styling."""
        from PySide6.QtWidgets import QLabel
        label = QLabel(text)
        label.setFont(QFont("Arial", 12, QFont.Bold))
        return label

    def _setup_menu(self):
        """Setup the menu bar."""
        menubar = self.menuBar()

        # File menu
        file_menu = menubar.addMenu("File")

        load_action = QAction("Load PGNs", self)
        load_action.triggered.connect(lambda: self.controller.load_pgns_from_file(self))
        file_menu.addAction(load_action)

        download_action = QAction("Download from Chess.com", self)
        download_action.triggered.connect(lambda: self.controller.download_games_from_chess_com(self))
        file_menu.addAction(download_action)

        load_cache_action = QAction("Load from Cache", self)
        load_cache_action.triggered.connect(lambda: self.controller.load_from_cache(self))
        file_menu.addAction(load_cache_action)

    def _connect_signals(self):
        """Connect signals between components and controller."""
        # Position list selection
        self.position_list.connect_item_clicked(self.controller.handle_position_selected)

        # Move explorer selection
        self.move_explorer.connect_item_clicked(self.controller.handle_move_clicked)

        # Controller signals
        self.controller.position_selected.connect(self._on_position_selected)
        self.controller.position_loaded.connect(self._on_position_loaded)
        self.controller.analysis_finished.connect(self._on_analysis_finished)
        self.controller.progress_updated.connect(self._on_progress_updated)
        self.controller.board_updated.connect(self._on_board_updated)

        # Navigation signals
        self.game_navigation.game_changed.connect(self._on_game_changed)
        self.move_navigation.move_changed.connect(self._on_move_changed)

    def _on_position_selected(self, fen: str, stats):
        """Handle position selection."""
        # Update position stats
        win_rate = (stats.wins + 0.5 * stats.draws) / stats.games
        stats_text = f"""Position Performance:
Win Rate: {win_rate:.1%}
Record: {stats.wins}-{stats.losses}-{stats.draws} in {stats.games} games

FEN: {fen}

Loading games..."""

        self.position_stats.setText(stats_text)

        # Show loading in move explorer
        self.move_explorer.show_loading()

    def _on_position_loaded(self, fen: str, position_data, stats):
        """Handle position data loaded."""
        if stats:
            # Update position stats with game count
            win_rate = (stats.wins + 0.5 * stats.draws) / stats.games
            stats_text = f"""Position Performance:
Win Rate: {win_rate:.1%}
Record: {stats.wins}-{stats.losses}-{stats.draws} in {stats.games} games

FEN: {fen}

Games with this position: {len(position_data.games)}"""

            self.position_stats.setText(stats_text)

            # Load games into navigator
            self.controller.game_navigator.load_games(position_data.games)

            # Update navigation UI
            self.game_navigation.update_navigation()
            self.move_navigation.update_navigation()

            # Load current game if any
            if position_data.games:
                self._load_current_game()

        # Build and display move tree
        self.move_explorer.build_move_tree(position_data)

    def _on_analysis_finished(self, fen_builder):
        """Handle analysis completion."""
        self.progress_bar.setVisible(False)
        self.position_list.populate_positions(fen_builder)

    def _on_progress_updated(self, progress: int):
        """Handle progress updates."""
        self.progress_bar.setVisible(True)
        self.progress_bar.setValue(progress)

    def _on_board_updated(self, board):
        """Handle board updates."""
        self.chess_board.set_board(board)

    def _on_game_changed(self):
        """Handle game navigation changes."""
        self._load_current_game()
        self.move_navigation.update_navigation()

    def _on_move_changed(self):
        """Handle move navigation changes."""
        self.move_navigation.update_navigation()

    def _load_current_game(self):
        """Load and display current game information."""
        game_info = self.controller.game_navigator.get_current_game_info()
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
        move_text = self.controller.game_navigator.format_game_moves()
        self.moves_text.setPlainText(move_text)

    def keyPressEvent(self, event):
        """Handle keyboard shortcuts."""
        key = event.key()

        # Arrow keys for move navigation
        if key == Qt.Key_Left:
            self.move_navigation._move_back()
        elif key == Qt.Key_Right:
            self.move_navigation._move_forward()
        elif key == Qt.Key_Up:
            self.game_navigation._previous_game()
        elif key == Qt.Key_Down:
            self.game_navigation._next_game()
        elif key == Qt.Key_Home:
            self.move_navigation._goto_start()
        elif key == Qt.Key_End:
            self.move_navigation._goto_end()
        else:
            super().keyPressEvent(event)

    def closeEvent(self, event):
        """Handle window close."""
        self.controller.cleanup()
        event.accept()