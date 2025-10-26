"""
Mode system for the chess UI.

Defines the base Mode class and specific mode implementations.
Each mode controls what appears in the left and right panels.
"""
from abc import ABC, abstractmethod
from typing import List, Optional
from PySide6.QtWidgets import QWidget
from PySide6.QtCore import QObject, Signal


class Mode(QObject):
    """
    Base class for UI modes.

    Each mode defines:
    - What widget appears in the left panel
    - What tabs appear in the right panel
    - How interactions work
    """

    # Signals
    board_position_changed = Signal(object)  # chess.Board
    mode_changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._left_panel = None
        self._right_tabs = []

    @abstractmethod
    def get_left_panel(self) -> QWidget:
        """Return the widget for the left panel."""
        pass

    @abstractmethod
    def get_right_tabs(self) -> List[tuple]:
        """
        Return list of (tab_name, tab_widget) tuples for right panel.

        Example:
            [("PGN", PGNWidget()), ("Games", GamesWidget())]
        """
        pass

    @abstractmethod
    def activate(self):
        """Called when this mode becomes active."""
        pass

    @abstractmethod
    def deactivate(self):
        """Called when switching away from this mode."""
        pass

    @property
    def mode_name(self) -> str:
        """Human-readable name for this mode."""
        return self.__class__.__name__.replace("Mode", "")


class TacticsMode(Mode):
    """
    Tactics training mode.

    Uses the shared center board for displaying positions.
    Control panel appears in the right tabs.
    """

    def __init__(self, tactics_widget, parent=None):
        super().__init__(parent)
        self.tactics_widget = tactics_widget
        self._info_panel = None
        self._board_widget = None

    def get_left_panel(self) -> QWidget:
        """Return simple info panel for tactics mode."""
        if self._info_panel is None:
            from PySide6.QtWidgets import QLabel, QVBoxLayout, QWidget
            self._info_panel = QWidget()
            layout = QVBoxLayout(self._info_panel)
            label = QLabel("Tactics Training Mode")
            label.setWordWrap(True)
            layout.addWidget(label)
            layout.addStretch()
        return self._info_panel

    def get_right_tabs(self) -> List[tuple]:
        """Return tactics controls in right panel."""
        return [("Tactics", self.tactics_widget)]

    def activate(self):
        """Activate tactics mode - connect to shared board."""
        # This will be called after the mode is set, so we can get the board from parent
        pass

    def deactivate(self):
        """Deactivate tactics mode."""
        pass

    def set_board_widget(self, board_widget):
        """Called by ThreePanelWidget to provide the shared board."""
        self._board_widget = board_widget
        self.tactics_widget.set_board_widget(board_widget)
        # Connect tactics signals to board
        self.tactics_widget.board_position_changed.connect(
            lambda board: self.board_position_changed.emit(board)
        )


class PositionAnalysisMode(Mode):
    """Position analysis mode for viewing weak/strong positions."""

    def __init__(self, analysis_data, parent=None):
        super().__init__(parent)
        self.analysis_data = analysis_data  # PositionAnalysis instance
        self._fen_list_widget = None
        self._pgn_widget = None
        self._games_widget = None
        self.current_fen = None

    def get_left_panel(self) -> QWidget:
        """Return FEN list with win rates."""
        if self._fen_list_widget is None:
            from widgets.fen_list import FenListWidget
            self._fen_list_widget = FenListWidget(self.analysis_data)
            self._fen_list_widget.fen_selected.connect(self._on_fen_selected)
        return self._fen_list_widget

    def get_right_tabs(self) -> List[tuple]:
        """Return PGN and Games tabs."""
        tabs = []

        # PGN tab
        if self._pgn_widget is None:
            from widgets.pgn_viewer import PGNViewerWidget
            self._pgn_widget = PGNViewerWidget()
            self._pgn_widget.position_changed.connect(
                lambda board: self.board_position_changed.emit(board)
            )
        tabs.append(("PGN", self._pgn_widget))

        # Games tab
        if self._games_widget is None:
            from widgets.games_list import GamesListWidget
            self._games_widget = GamesListWidget()
            self._games_widget.game_selected.connect(self._on_game_selected)
        tabs.append(("Games", self._games_widget))

        return tabs

    def activate(self):
        """Activate position analysis mode."""
        pass

    def deactivate(self):
        """Deactivate position analysis mode."""
        pass

    def _on_fen_selected(self, fen: str):
        """Handle FEN selection from left panel."""
        self.current_fen = fen

        # Update board
        import chess
        try:
            board = chess.Board(fen)
            self.board_position_changed.emit(board)
        except Exception:
            pass

        # Update games list to show games with this FEN
        if self._games_widget:
            games = self.analysis_data.get_games_for_fen(fen)
            self._games_widget.set_games(games, fen)

    def _on_game_selected(self, game_info):
        """Handle game selection from games list."""
        # Load the game in PGN viewer
        if self._pgn_widget and game_info.pgn_text:
            self._pgn_widget.load_pgn(game_info.pgn_text)
