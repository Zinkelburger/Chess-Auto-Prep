"""
FEN list widget for displaying position statistics.
"""
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QListWidget, QListWidgetItem,
    QLabel, QComboBox, QHBoxLayout, QSpinBox
)
from PySide6.QtCore import Signal, Qt
from PySide6.QtGui import QFont

from core.models import PositionAnalysis


class FenListWidget(QWidget):
    """
    Widget displaying a list of FENs with statistics.

    Allows filtering and sorting.
    """

    fen_selected = Signal(str)  # Emits FEN when selected

    def __init__(self, analysis: PositionAnalysis, parent=None):
        super().__init__(parent)
        self.analysis = analysis
        self._setup_ui()
        self._populate_list()

    def _setup_ui(self):
        """Setup the UI components."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(5, 5, 5, 5)

        # Header
        header = QLabel("<b>Position Analysis</b>")
        header.setAlignment(Qt.AlignCenter)
        layout.addWidget(header)

        # Filters
        filter_layout = QHBoxLayout()

        # Min games filter
        filter_layout.addWidget(QLabel("Min games:"))
        self.min_games_spin = QSpinBox()
        self.min_games_spin.setMinimum(1)
        self.min_games_spin.setValue(3)
        self.min_games_spin.setMaximum(50)
        self.min_games_spin.valueChanged.connect(self._populate_list)
        filter_layout.addWidget(self.min_games_spin)

        layout.addLayout(filter_layout)

        # Sort by
        sort_layout = QHBoxLayout()
        sort_layout.addWidget(QLabel("Sort by:"))
        self.sort_combo = QComboBox()
        self.sort_combo.addItems(["Lowest Win Rate", "Most Games", "Most Losses"])
        self.sort_combo.currentTextChanged.connect(self._populate_list)
        sort_layout.addWidget(self.sort_combo)
        layout.addLayout(sort_layout)

        # List
        self.list_widget = QListWidget()
        self.list_widget.itemClicked.connect(self._on_item_clicked)
        layout.addWidget(self.list_widget)

    def _populate_list(self):
        """Populate the list with positions."""
        self.list_widget.clear()

        # Get sort key
        sort_map = {
            "Lowest Win Rate": "win_rate",
            "Most Games": "games",
            "Most Losses": "losses"
        }
        sort_by = sort_map[self.sort_combo.currentText()]

        # Get sorted positions
        positions = self.analysis.get_sorted_positions(
            min_games=self.min_games_spin.value(),
            sort_by=sort_by
        )

        # Add to list
        for i, stats in enumerate(positions[:50], 1):  # Limit to 50
            item = QListWidgetItem()

            # Format the display text
            text = (
                f"#{i}: {stats.win_rate_percent:.1f}% "
                f"({stats.wins}-{stats.losses}-{stats.draws} in {stats.games})\n"
                f"{stats.fen[:40]}..."
            )

            item.setText(text)
            item.setData(Qt.UserRole, stats.fen)  # Store FEN in item data

            # Color code by win rate
            if stats.win_rate < 0.3:
                item.setBackground(Qt.red)
            elif stats.win_rate < 0.4:
                item.setBackground(Qt.yellow)

            self.list_widget.addItem(item)

    def _on_item_clicked(self, item: QListWidgetItem):
        """Handle item click."""
        fen = item.data(Qt.UserRole)
        if fen:
            self.fen_selected.emit(fen)
