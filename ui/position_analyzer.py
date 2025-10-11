"""
Position analysis widget and related functionality.
"""
from typing import List, Optional
from PySide6.QtWidgets import QWidget, QVBoxLayout, QLabel, QListWidget, QListWidgetItem
from PySide6.QtCore import Qt, QThread, Signal
from PySide6.QtGui import QFont

import chess
from move_database import MoveDatabase


class PositionLoadThread(QThread):
    """Background thread for loading position data from games."""
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


class PositionListWidget(QWidget):
    """Widget for displaying a list of problematic positions."""

    def __init__(self):
        super().__init__()
        self._setup_ui()

    def _setup_ui(self):
        layout = QVBoxLayout(self)

        self.label = QLabel("Problematic Positions")
        self.label.setFont(QFont("Arial", 12, QFont.Bold))
        layout.addWidget(self.label)

        self.list_widget = QListWidget()
        layout.addWidget(self.list_widget)

    def populate_positions(self, fen_builder):
        """Populate the list with positions from FEN builder."""
        self.list_widget.clear()

        if not fen_builder:
            return

        # Get worst performing positions
        qualifying_positions = [
            (fen, stats) for fen, stats in fen_builder.fen_map.items()
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
            self.list_widget.addItem(item)

    def connect_item_clicked(self, callback):
        """Connect item click handler."""
        self.list_widget.itemClicked.connect(callback)


class MoveExplorerWidget(QWidget):
    """Widget for exploring moves from a position."""

    def __init__(self):
        super().__init__()
        self._setup_ui()

    def _setup_ui(self):
        layout = QVBoxLayout(self)

        label = QLabel("Moves from this position:")
        label.setFont(QFont("Arial", 10, QFont.Bold))
        layout.addWidget(label)

        self.list_widget = QListWidget()
        layout.addWidget(self.list_widget)

    def build_move_tree(self, position_data):
        """Build move tree from position data."""
        self.list_widget.clear()

        if not position_data.move_stats:
            self.list_widget.addItem("No moves from this position")
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
            self.list_widget.addItem(item)

    def show_loading(self):
        """Show loading message."""
        self.list_widget.clear()
        self.list_widget.addItem("Loading...")

    def connect_item_clicked(self, callback):
        """Connect item click handler."""
        self.list_widget.itemClicked.connect(callback)