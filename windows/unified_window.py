"""
Unified chess UI with three-panel layout.

Left panel: Mode-specific content (FEN list, tactics info, etc.)
Center: Chess board
Right panel: Tabs (PGN viewer, games list, tactics controls, etc.)
"""
from PySide6.QtWidgets import (
    QWidget, QHBoxLayout, QVBoxLayout, QTabWidget, QSplitter,
    QLabel
)
from PySide6.QtCore import Qt

from widgets.chess_board import ChessBoardWidget
from core.modes import Mode


class UnifiedChessWidget(QWidget):
    """
    Unified chess interface with mode-based three-panel layout.

    Modes control what appears in left and right panels.
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        self.current_mode = None
        self._setup_ui()

    def _setup_ui(self):
        """Setup the three-panel layout."""
        main_layout = QHBoxLayout(self)
        main_layout.setContentsMargins(0, 0, 0, 0)

        # Create splitter for resizable panels
        self.splitter = QSplitter(Qt.Horizontal)

        # Left panel container
        self.left_panel_container = QWidget()
        self.left_panel_layout = QVBoxLayout(self.left_panel_container)
        self.left_panel_layout.setContentsMargins(0, 0, 0, 0)

        # Placeholder for left panel
        self.left_panel_widget = QLabel("No mode selected")
        self.left_panel_widget.setAlignment(Qt.AlignCenter)
        self.left_panel_layout.addWidget(self.left_panel_widget)

        # Center panel - chess board
        self.board_container = QWidget()
        board_layout = QVBoxLayout(self.board_container)
        board_layout.setContentsMargins(5, 5, 5, 5)

        self.chess_board = ChessBoardWidget()
        board_layout.addWidget(self.chess_board)

        # Right panel - tabs
        self.right_tabs = QTabWidget()

        # Add panels to splitter
        self.splitter.addWidget(self.left_panel_container)
        self.splitter.addWidget(self.board_container)
        self.splitter.addWidget(self.right_tabs)

        # Set initial sizes (25% left, 50% center, 25% right)
        self.splitter.setStretchFactor(0, 2)
        self.splitter.setStretchFactor(1, 3)
        self.splitter.setStretchFactor(2, 2)

        main_layout.addWidget(self.splitter)

    def set_mode(self, mode: Mode):
        """
        Switch to a new mode.

        Updates left panel and right tabs based on mode.
        """
        # Deactivate current mode
        if self.current_mode:
            self.current_mode.deactivate()
            self.current_mode.board_position_changed.disconnect()

        self.current_mode = mode

        # Update left panel
        self._update_left_panel()

        # Update right tabs
        self._update_right_tabs()

        # Connect signals
        mode.board_position_changed.connect(self._on_board_position_changed)

        # Activate mode
        mode.activate()

    def _update_left_panel(self):
        """Update the left panel based on current mode."""
        # Remove old widget
        if self.left_panel_widget:
            self.left_panel_layout.removeWidget(self.left_panel_widget)
            self.left_panel_widget.setParent(None)

        # Add new widget from mode
        self.left_panel_widget = self.current_mode.get_left_panel()
        if self.left_panel_widget:
            self.left_panel_layout.addWidget(self.left_panel_widget)
        else:
            # Placeholder if no left panel
            self.left_panel_widget = QLabel(f"{self.current_mode.mode_name} Mode")
            self.left_panel_widget.setAlignment(Qt.AlignCenter)
            self.left_panel_layout.addWidget(self.left_panel_widget)

    def _update_right_tabs(self):
        """Update right tabs based on current mode."""
        # Clear existing tabs
        self.right_tabs.clear()

        # Add tabs from mode
        tabs = self.current_mode.get_right_tabs()
        for tab_name, tab_widget in tabs:
            self.right_tabs.addTab(tab_widget, tab_name)

        # Hide tab bar if only one tab
        self.right_tabs.tabBar().setVisible(len(tabs) > 1)

    def _on_board_position_changed(self, board):
        """Handle position change from mode."""
        self.chess_board.set_board(board)

    def get_board_widget(self) -> ChessBoardWidget:
        """Get the chess board widget."""
        return self.chess_board
