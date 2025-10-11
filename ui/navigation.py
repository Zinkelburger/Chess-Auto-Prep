"""
Navigation components for game and move navigation.
"""
from PySide6.QtWidgets import QWidget, QHBoxLayout, QPushButton, QLabel
from PySide6.QtCore import Signal

from game_navigator import GameNavigator


class GameNavigationWidget(QWidget):
    """Widget for navigating between games."""

    game_changed = Signal()

    def __init__(self, game_navigator: GameNavigator):
        super().__init__()
        self.game_navigator = game_navigator
        self._setup_ui()

    def _setup_ui(self):
        layout = QHBoxLayout(self)

        self.prev_button = QPushButton("← Previous Game")
        self.prev_button.clicked.connect(self._previous_game)
        layout.addWidget(self.prev_button)

        self.game_label = QLabel("No game selected")
        layout.addWidget(self.game_label)

        self.next_button = QPushButton("Next Game →")
        self.next_button.clicked.connect(self._next_game)
        layout.addWidget(self.next_button)

        self.update_navigation()

    def _previous_game(self):
        if self.game_navigator.previous_game():
            self.update_navigation()
            self.game_changed.emit()

    def _next_game(self):
        if self.game_navigator.next_game():
            self.update_navigation()
            self.game_changed.emit()

    def update_navigation(self):
        """Update navigation button states and labels."""
        if not self.game_navigator.has_games():
            self.game_label.setText("No games found")
            self.prev_button.setEnabled(False)
            self.next_button.setEnabled(False)
        else:
            total_games = len(self.game_navigator.games)
            self.game_label.setText(f"Game {self.game_navigator.current_game_index + 1} of {total_games}")
            self.prev_button.setEnabled(self.game_navigator.can_previous_game())
            self.next_button.setEnabled(self.game_navigator.can_next_game())


class MoveNavigationWidget(QWidget):
    """Widget for navigating through moves in a game."""

    move_changed = Signal()

    def __init__(self, game_navigator: GameNavigator):
        super().__init__()
        self.game_navigator = game_navigator
        self._setup_ui()

    def _setup_ui(self):
        layout = QHBoxLayout(self)

        self.start_button = QPushButton("|◀ Start")
        self.start_button.clicked.connect(self._goto_start)
        layout.addWidget(self.start_button)

        self.back_button = QPushButton("◀ Back")
        self.back_button.clicked.connect(self._move_back)
        layout.addWidget(self.back_button)

        self.move_label = QLabel("Move 0")
        layout.addWidget(self.move_label)

        self.forward_button = QPushButton("Forward ▶")
        self.forward_button.clicked.connect(self._move_forward)
        layout.addWidget(self.forward_button)

        self.end_button = QPushButton("End ▶|")
        self.end_button.clicked.connect(self._goto_end)
        layout.addWidget(self.end_button)

        self.update_navigation()

    def _goto_start(self):
        if self.game_navigator.goto_start():
            self.update_navigation()
            self.move_changed.emit()

    def _move_back(self):
        if self.game_navigator.move_back():
            self.update_navigation()
            self.move_changed.emit()

    def _move_forward(self):
        if self.game_navigator.move_forward():
            self.update_navigation()
            self.move_changed.emit()

    def _goto_end(self):
        if self.game_navigator.goto_end():
            self.update_navigation()
            self.move_changed.emit()

    def update_navigation(self):
        """Update move navigation button states."""
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