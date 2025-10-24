"""
Games list widget for displaying games associated with a position.
"""
from typing import List
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QListWidget, QListWidgetItem, QLabel
)
from PySide6.QtCore import Signal, Qt

from core.models import GameInfo


class GamesListWidget(QWidget):
    """
    Widget displaying a list of games.

    Shows games that contain a specific position.
    """

    game_selected = Signal(object)  # Emits GameInfo

    def __init__(self, parent=None):
        super().__init__(parent)
        self.games = []
        self.current_fen = None
        self._setup_ui()

    def _setup_ui(self):
        """Setup the UI."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(5, 5, 5, 5)

        # Header
        self.header_label = QLabel("<b>Games</b>")
        self.header_label.setAlignment(Qt.AlignCenter)
        layout.addWidget(self.header_label)

        # Info label
        self.info_label = QLabel("Select a position to see games")
        self.info_label.setWordWrap(True)
        self.info_label.setAlignment(Qt.AlignCenter)
        layout.addWidget(self.info_label)

        # List
        self.list_widget = QListWidget()
        self.list_widget.itemDoubleClicked.connect(self._on_item_double_clicked)
        layout.addWidget(self.list_widget)

    def set_games(self, games: List[GameInfo], fen: str = None):
        """Set the games to display."""
        self.games = games
        self.current_fen = fen
        self._populate_list()

    def _populate_list(self):
        """Populate the list with games."""
        self.list_widget.clear()

        if not self.games:
            self.info_label.setText("No games found for this position")
            return

        self.info_label.setText(f"Found {len(self.games)} games with this position")

        for game in self.games:
            item = QListWidgetItem()

            # Format display text
            text = f"{game.title}"
            if game.subtitle:
                text += f"\n{game.subtitle}"

            item.setText(text)
            item.setData(Qt.UserRole, game)  # Store GameInfo

            self.list_widget.addItem(item)

    def _on_item_double_clicked(self, item: QListWidgetItem):
        """Handle item double-click."""
        game_info = item.data(Qt.UserRole)
        if game_info:
            self.game_selected.emit(game_info)
