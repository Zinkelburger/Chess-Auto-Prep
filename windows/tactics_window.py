"""
Tactics training window - clean implementation using new architecture.
"""
from datetime import datetime

import chess
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QTextEdit, QProgressBar, QFrame, QMessageBox, QSplitter, QCheckBox,
    QSizePolicy
)
from PySide6.QtCore import Qt, Signal, QTimer
from PySide6.QtGui import QFont
from PySide6.QtWidgets import QApplication

from core.tactics import TacticsDatabase, TacticsEngine, TacticsResult
from widgets.chess_board import ChessBoardWidget
from config import APP_NAME



class TacticsWindow(QWidget):
    """
    Modern tactics training window with clean separation of concerns.
    """

    # Signals
    session_finished = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"{APP_NAME} - Tactics Trainer")
        # We start with a reasonable size, but the layout handles dynamic resizing.
        self.setGeometry(200, 200, 1000, 700)

        # Core components
        self.database = TacticsDatabase()
        self.engine = TacticsEngine()

        # State
        self.current_position = None
        self.position_solved = False
        self.start_time = None
        self.auto_advance = True  # Auto-advance setting

        # UI setup
        self._setup_ui()
        self._connect_signals()

        # Set initial button visibility based on auto-advance setting
        self.next_btn.setVisible(not self.auto_advance)

        # Auto-load positions on startup
        self._load_positions()
        if self.database.positions:
            self.new_session_btn.setEnabled(True)

    # =========================================================================
    # SIMPLIFIED UI SETUP (CLEANED)
    # =========================================================================

    def resizeEvent(self, event):
        """
        The old manual layout logic is removed. Layout is now handled
        automatically by the QHBoxLayout with stretches.
        """
        super().resizeEvent(event)

        from config import GUI_DEBUG

        # --- THE FIX ---
        # We must enforce the board's 1:1 aspect ratio manually.
        # The widget's height is determined by the window's height.
        # We read that height, and then *force* the widget's width
        # to be the same value.
        if hasattr(self, 'chess_board'):
            # Use the height of the board_panel_widget as the constraint
            # This is more stable than the board's own height which is in flux.
            constrained_height = self.board_panel_widget.height()

            # Set a FIXED size for the board to force it square
            self.chess_board.setFixedSize(constrained_height, constrained_height)

            # We must also update the panel's height to match
            # (In case it's shorter for some reason)
            self.right_panel.setMinimumHeight(constrained_height)

        if GUI_DEBUG:
            print(f"TacticsWindow resizeEvent: window size = {self.width()}x{self.height()}")
            if hasattr(self, 'board_panel_widget'):
                print(f"  board_panel_widget size = {self.board_panel_widget.width()}x{self.board_panel_widget.height()}")
            if hasattr(self, 'chess_board'):
                # This width should now equal the height
                print(f"  chess_board widget size = {self.chess_board.width()}x{self.chess_board.height()} (ENFORCED SQUARE)")
            if hasattr(self, 'right_panel'):
                print(f"  right_panel size = {self.right_panel.width()}x{self.right_panel.height()}")

    # Removed _update_board_centering entirely as requested.

    def _setup_ui(self):
        """
        Setup the user interface to fill the window:
        [Board + Panel]
        The inner layout handles splitting space between board and panel.
        """
        self.main_layout = QHBoxLayout(self)
        self.main_layout.setContentsMargins(20, 20, 20, 20)
        self.main_layout.setSpacing(0)  # No spacing, margins handle it

        # --- 1. Board + Panel Container (The main content block) ---

        # This inner widget holds the board and panel side-by-side
        self.board_panel_widget = QWidget()
        from config import GUI_DEBUG
        if GUI_DEBUG:
            # Add debugging: give the container widget a visible background
            self.board_panel_widget.setStyleSheet("background-color: lightyellow; border: 2px solid orange;")

        self.board_panel_container = QHBoxLayout(self.board_panel_widget)
        self.board_panel_container.setSpacing(10)  # Gap between board and panel
        self.board_panel_container.setContentsMargins(0, 0, 0, 0)

        # 1.1 Add chess board
        self.chess_board = ChessBoardWidget()
        self.chess_board.set_interactive(True)
        # --- FIX: Set a square size policy ---
        # This tells the layout to prefer expanding vertically
        # and to base its width on its height.
        self.chess_board.setSizePolicy(QSizePolicy.MinimumExpanding, QSizePolicy.Expanding)

        if GUI_DEBUG:
            # Add debugging: give the chess board a visible background
            self.chess_board.setStyleSheet("background-color: lightblue; border: 2px solid blue;")

        # --- FIX: Add chess board with stretch factor 0 ---
        self.board_panel_container.addWidget(self.chess_board, 0)
        if GUI_DEBUG:
            print(f"Added chess board to layout with stretch factor 0")

        # 1.2 Add right panel
        self.right_panel = self._create_control_panel()

        if GUI_DEBUG:
            # Add debugging: give the panel a visible background
            self.right_panel.setStyleSheet("background-color: lightgreen; border: 2px solid green;")

        # Add panel (stretch factor 0: it only takes the space it needs)
        self.board_panel_container.addWidget(self.right_panel, 0)
        if GUI_DEBUG:
            print(f"Added right panel to layout with stretch factor 0")

        # --- 2. Main Layout (Centering the board+panel combo) ---

        # Left stretch to center the board+panel combo
        self.main_layout.addStretch(1)

        # Add the board/panel container (stretch factor 0: it takes only the space it needs)
        self.main_layout.addWidget(self.board_panel_widget, 0)

        # Right stretch to center the board+panel combo
        self.main_layout.addStretch(1)

        if GUI_DEBUG:
            print(f"Added centering stretches: [Stretch(1)] [Board+Panel(0)] [Stretch(1)]")

    # =========================================================================
    # END OF SIMPLIFIED UI SETUP
    # =========================================================================

    def _create_control_panel(self) -> QWidget:
        """Create the control panel."""
        panel = QWidget()
        panel.setMinimumWidth(280)  # Minimum width to prevent crushing
        panel.setMaximumWidth(400)  # Maximum width to force board expansion
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(5, 0, 0, 0)  # Small left margin to not be completely flush

        # Position info
        self.position_info = QLabel("")
        self.position_info.setWordWrap(True)
        self.position_info.setFont(QFont("Arial", 10))
        layout.addWidget(self.position_info)


        # Feedback (minimal, no frame)
        self.feedback_label = QLabel("")
        self.feedback_label.setWordWrap(True)
        self.feedback_label.setFont(QFont("Arial", 11))
        layout.addWidget(self.feedback_label)

        # Solution display area
        self.solution_widget = QWidget()
        self.solution_widget.setVisible(False)
        solution_layout = QVBoxLayout(self.solution_widget)
        solution_layout.setContentsMargins(2, 2, 2, 2)

        # Solution text with Copy FEN button on the same line
        solution_text_layout = QHBoxLayout()

        self.solution_text = QLabel()
        self.solution_text.setFont(QFont("Courier", 10))  # Increased from 8 to 10
        self.solution_text.setWordWrap(True)
        self.solution_text.setTextInteractionFlags(Qt.TextSelectableByMouse)
        solution_text_layout.addWidget(self.solution_text)

        # Add stretch to give some space, but not fully right-align
        solution_text_layout.addStretch()

        self.copy_fen_btn = QPushButton("Copy FEN")
        self.copy_fen_btn.setMaximumWidth(85)  # Slightly wider than before
        self.copy_fen_btn.setToolTip("Copy FEN to clipboard")
        self.copy_fen_btn.clicked.connect(self._copy_fen)
        solution_text_layout.addWidget(self.copy_fen_btn)

        # Add a small fixed spacer to give some breathing room from the right edge
        solution_text_layout.addSpacing(8)

        solution_layout.addLayout(solution_text_layout)
        layout.addWidget(self.solution_widget)

        # Action buttons
        self._create_action_buttons(layout)

        # Settings
        self._create_settings(layout)

        # Session controls
        self._create_session_controls(layout)

        # Stats
        self.stats_label = QLabel("")
        self.stats_label.setFont(QFont("Arial", 9))
        layout.addWidget(self.stats_label)

        layout.addStretch()
        return panel

    def _create_action_buttons(self, layout):
        """Create action buttons."""
        self.action_layout = QHBoxLayout()

        self.solution_btn = QPushButton("Show Solution")
        self.solution_btn.clicked.connect(self._show_solution)
        self.action_layout.addWidget(self.solution_btn)

        self.next_btn = QPushButton("Next Position")
        self.next_btn.clicked.connect(self._next_position)
        self.next_btn.setEnabled(False)
        self.action_layout.addWidget(self.next_btn)

        # Create a widget to contain the action buttons so we can hide it
        self.action_widget = QWidget()
        self.action_widget.setLayout(self.action_layout)
        self.action_widget.setVisible(False)  # Initially hidden
        layout.addWidget(self.action_widget)

    def _create_settings(self, layout):
        """Create settings controls."""
        settings_layout = QHBoxLayout()

        self.auto_advance_checkbox = QCheckBox("Auto-advance to next position")
        self.auto_advance_checkbox.setChecked(self.auto_advance)
        self.auto_advance_checkbox.toggled.connect(self._toggle_auto_advance)
        settings_layout.addWidget(self.auto_advance_checkbox)

        layout.addLayout(settings_layout)

    def _toggle_auto_advance(self, checked: bool):
        """Toggle auto-advance setting."""
        self.auto_advance = checked
        # Hide/show next button based on auto-advance setting
        self.next_btn.setVisible(not checked)

    def _create_session_controls(self, layout):
        """Create session control buttons."""
        session_layout = QHBoxLayout()

        self.new_session_btn = QPushButton("Start Practice Session")
        self.new_session_btn.clicked.connect(self._start_new_session)
        session_layout.addWidget(self.new_session_btn)

        layout.addLayout(session_layout)

    def _connect_signals(self):
        """Connect widget signals."""
        self.chess_board.move_made.connect(self._on_move_made)

    def _load_positions(self):
        """Load tactics positions."""
        count = self.database.load_positions()
        if count == 0:
            self.position_info.setText(
                "No tactics positions found.\n\n"
                "Use the menu to:\n"
                "• Import > Import from Lichess\n"
                "• Analysis > Analyze PGNs for Tactics"
            )
            self.new_session_btn.setEnabled(False)
            return

        self.position_info.setText(f"{count} tactics positions available.")
        self.new_session_btn.setEnabled(True)

    def _start_new_session(self):
        """Start a new tactics session."""
        self.database.start_session()
        # Hide the start button during session
        self.new_session_btn.setVisible(False)
        self._load_next_position()
        self._update_session_stats()

    def _load_next_position(self):
        """Load the next position for review."""
        positions = self.database.get_positions_for_review(1)
        if not positions:
            self._session_complete()
            return

        self.current_position = positions[0]
        self.position_solved = False
        self.start_time = datetime.now()

        # Set up board
        board = chess.Board(self.current_position.fen)
        self.chess_board.set_board(board)
        self.chess_board.set_orientation(board.turn == chess.WHITE)
        self.chess_board.set_interactive(True)

        # Update UI
        self._update_position_info()
        self._reset_ui_for_new_position()

        # Show action buttons now that we have a position
        self.action_widget.setVisible(True)

    def _update_position_info(self):
        """Update position information display."""
        if not self.current_position:
            return

        pos = self.current_position

        # Convert user_move from UCI to SAN for display
        try:
            move = chess.Move.from_uci(pos.user_move)
            original_move_san = pos.board.san(move)
        except (ValueError, chess.InvalidMoveError):
            original_move_san = pos.user_move

        info_text = f"""<b>{pos.context}</b><br>
Mistake: {pos.mistake_type.value}<br>
Game: {pos.game_info.white} vs {pos.game_info.black}<br>
Difficulty: {pos.difficulty}/5<br>
Success rate: {pos.success_rate:.1%}<br>
Reviews: {pos.review_count}<br>
You played: {original_move_san}"""

        self.position_info.setText(info_text)

    def _reset_ui_for_new_position(self):
        """Reset UI for a new position."""
        self.feedback_label.setText("")
        self.solution_widget.setVisible(False)
        self.solution_btn.setEnabled(True)
        self.next_btn.setEnabled(False)

    def _on_move_made(self, move_uci: str):
        """Handle move made on board."""
        if self.position_solved or not self.current_position:
            return

        # Execute the move visually on the board first
        try:
            move = chess.Move.from_uci(move_uci)
            if move in self.current_position.board.legal_moves:
                # Make the move on our position copy
                temp_board = self.current_position.board.copy()
                temp_board.push(move)

                # Update the visual board
                self.chess_board.set_board(temp_board)
        except (ValueError, chess.InvalidMoveError):
            pass  # Invalid move, just continue with checking

        # Check the move
        result = self.engine.check_move(self.current_position, move_uci)
        time_taken = (datetime.now() - self.start_time).total_seconds()

        if result == TacticsResult.CORRECT:
            self._handle_correct_move(time_taken)
        elif result == TacticsResult.PARTIAL:
            self._handle_partial_move()
        else:
            self._handle_incorrect_move(time_taken, move_uci)

    def _handle_correct_move(self, time_taken: float):
        """Handle a correct move."""
        self.position_solved = True
        self.feedback_label.setText("Correct!")

        # Show the continuation if there's more to the correct line
        self._show_continuation_if_any()

        # Record the attempt
        self.database.record_attempt(
            self.current_position, TacticsResult.CORRECT, time_taken
        )

        self._update_session_stats()

        # Auto-advance or show next button
        if self.auto_advance:
            QTimer.singleShot(1500, self._next_position)  # 1.5 second delay
        else:
            self.next_btn.setEnabled(True)

    def _show_continuation_if_any(self):
        """Show the continuation of the correct line if it exists."""
        if not self.current_position.correct_line or len(self.current_position.correct_line) <= 1:
            return

        try:
            # Get the current board state (after user's move)
            current_board = self.chess_board.board.copy()

            # Play the next move in the correct line (opponent's response)
            if len(self.current_position.correct_line) > 1:
                next_move_san = self.current_position.correct_line[1]

                # Convert SAN to move and play it
                next_move = current_board.parse_san(next_move_san)
                current_board.push(next_move)

                # Update the visual board
                self.chess_board.set_board(current_board)

        except (ValueError, chess.InvalidMoveError):
            pass  # If we can't parse/play the continuation, just skip it

    def _handle_partial_move(self):
        """Handle a partially correct move."""
        self.feedback_label.setText("Good move, but not the best. Try again!")

    def _handle_incorrect_move(self, time_taken: float, move_uci: str):
        """Handle an incorrect move."""
        # Don't mark as solved - let them keep trying
        self.feedback_label.setText("Incorrect")

        # Reset the board to original position
        self.chess_board.set_board(self.current_position.board)
        self.chess_board.clear_selection()


    def _show_solution(self):
        """Show the solution."""
        if not self.current_position:
            return

        solution = self.engine.get_solution(self.current_position)

        # Display solution (FEN available via copy button)
        self.solution_text.setText(f"Solution: {solution}")
        self.solution_widget.setVisible(True)
        self.solution_btn.setEnabled(False)

    def _copy_fen(self):
        """Copy the current position FEN to clipboard."""
        if not self.current_position:
            return

        clipboard = QApplication.clipboard()
        clipboard.setText(self.current_position.fen)

    def _next_position(self):
        """Move to the next position."""
        self._load_next_position()

    def _session_complete(self):
        """Handle session completion."""
        session = self.database.current_session
        self.feedback_label.setText("Session complete!")

        QMessageBox.information(
            self, "Session Complete",
            f"Great work!\n\n"
            f"Positions attempted: {session.positions_attempted}\n"
            f"Correct: {session.positions_correct}\n"
            f"Incorrect: {session.positions_incorrect}\n"
            f"Accuracy: {session.positions_correct/max(1,session.positions_attempted):.1%}"
        )

        # Show start button again and hide action buttons
        self.new_session_btn.setVisible(True)
        self.action_widget.setVisible(False)
        self.session_finished.emit()

    def _update_session_stats(self):
        """Update session statistics display."""
        session = self.database.current_session
        if session.positions_attempted > 0:
            accuracy = session.positions_correct / session.positions_attempted
            self.stats_label.setText(
                f"Session: {session.positions_correct}/{session.positions_attempted} "
                f"({accuracy:.1%})"
            )
        else:
            self.stats_label.setText("")