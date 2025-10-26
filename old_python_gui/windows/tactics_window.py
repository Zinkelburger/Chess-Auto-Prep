"""
Tactics training controls panel - no board, just the control interface.
The board is shared from the main chess view.
"""
from datetime import datetime
import re
import logging
import io

import chess
import chess.pgn
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QTextEdit, QProgressBar, QFrame, QMessageBox, QSplitter, QCheckBox,
    QSizePolicy, QTabWidget
)
from PySide6.QtCore import Qt, Signal, QTimer
from PySide6.QtGui import QFont
from PySide6.QtWidgets import QApplication

from core.tactics import TacticsDatabase, TacticsEngine, TacticsResult
from config import APP_NAME



class TacticsWidget(QWidget):
    """
    Tactics training controls widget - manages tactics logic and UI controls.
    Uses an external shared board (passed via set_board_widget).
    """

    # Signals
    session_finished = Signal()
    board_position_changed = Signal(object)  # chess.Board

    # Logger
    logger = logging.getLogger(__name__)

    def __init__(self, parent=None):
        super().__init__(parent)

        # Core components
        self.database = TacticsDatabase()
        self.engine = TacticsEngine()

        # State
        self.current_position = None
        self.position_solved = False
        self.start_time = None
        self.auto_advance = True  # Auto-advance setting
        self.position_history = []  # Track position history for Previous button
        self.history_index = -1  # Current position in history

        # External board reference (set via set_board_widget)
        self.chess_board = None

        # Tab widgets
        self.tab_widget = None
        self.pgn_viewer = None

        # UI setup
        self._setup_ui()

        # Set initial button visibility based on auto-advance setting
        self.next_btn.setVisible(not self.auto_advance)

        # Auto-load positions on startup
        self._load_positions()
        if self.database.positions:
            self.new_session_btn.setEnabled(True)

    def set_board_widget(self, board_widget):
        """Set the external chess board widget to use."""
        self.chess_board = board_widget
        self._connect_signals()

    def _setup_ui(self):
        """Setup the tabbed interface."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(5, 5, 5, 5)

        # Create tab widget
        self.tab_widget = QTabWidget()
        layout.addWidget(self.tab_widget)

        # Create Tactic tab
        tactic_tab = self._create_tactic_tab()
        self.tab_widget.addTab(tactic_tab, "Tactic")

        # Create Analysis tab
        analysis_tab = self._create_analysis_tab()
        self.tab_widget.addTab(analysis_tab, "Analysis")

    def _create_tactic_tab(self) -> QWidget:
        """Create the Tactic tab with the control panel."""
        tab = QWidget()
        tab_layout = QVBoxLayout(tab)
        tab_layout.setContentsMargins(0, 0, 0, 0)

        # Add control panel
        control_panel = self._create_control_panel()
        tab_layout.addWidget(control_panel)

        return tab

    def _create_analysis_tab(self) -> QWidget:
        """Create the Analysis tab with PGN viewer."""
        tab = QWidget()
        tab_layout = QVBoxLayout(tab)
        tab_layout.setContentsMargins(0, 0, 0, 0)

        # Import and create PGN viewer
        from widgets.pgn_viewer import PGNViewerWidget
        self.pgn_viewer = PGNViewerWidget()

        # Connect PGN viewer to board
        self.pgn_viewer.position_changed.connect(self._on_analysis_position_changed)

        tab_layout.addWidget(self.pgn_viewer)

        return tab

    def _create_control_panel(self) -> QWidget:
        """Create the control panel."""
        panel = QWidget()
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(0, 0, 0, 0)

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
        self.action_layout = QVBoxLayout()

        # Top row: Solution, Analyze
        top_row = QHBoxLayout()
        self.solution_btn = QPushButton("Show Solution")
        self.solution_btn.clicked.connect(self._show_solution)
        top_row.addWidget(self.solution_btn)

        self.analyze_btn = QPushButton("Analyze")
        self.analyze_btn.clicked.connect(self._show_analysis)
        top_row.addWidget(self.analyze_btn)
        self.action_layout.addLayout(top_row)

        # Bottom row: Previous, Skip
        bottom_row = QHBoxLayout()
        self.prev_btn = QPushButton("Previous Position")
        self.prev_btn.clicked.connect(self._prev_position)
        self.prev_btn.setEnabled(False)
        bottom_row.addWidget(self.prev_btn)

        self.next_btn = QPushButton("Skip Position")
        self.next_btn.clicked.connect(self._next_position)
        self.next_btn.setEnabled(False)
        bottom_row.addWidget(self.next_btn)
        self.action_layout.addLayout(bottom_row)

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
        """Connect widget signals (only if board is set)."""
        if self.chess_board:
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
        # Reset history
        self.position_history = []
        self.history_index = -1
        # Hide the start button during session
        self.new_session_btn.setVisible(False)
        self._load_next_position()
        self._update_session_stats()

    def _load_next_position(self):
        """Load the next position for review."""
        if not self.chess_board:
            return

        positions = self.database.get_positions_for_review(1)
        if not positions:
            self._session_complete()
            return

        self.current_position = positions[0]
        self.position_solved = False
        self.start_time = datetime.now()

        # Add to history (only if we're not navigating backwards)
        if self.history_index == len(self.position_history) - 1:
            self.position_history.append(self.current_position)
            self.history_index = len(self.position_history) - 1
        else:
            # We went back and then forward, update from this point
            self.history_index += 1
            if self.history_index >= len(self.position_history):
                self.position_history.append(self.current_position)
                self.history_index = len(self.position_history) - 1

        # Update Previous button state
        self.prev_btn.setEnabled(self.history_index > 0)

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

        # Build info text with mistake analysis if available
        info_text = f"<b>{pos.context}</b><br>"

        if pos.mistake_analysis:
            info_text += f"<b>{pos.mistake_analysis}</b><br><br>"
        else:
            info_text += f"Mistake: {pos.mistake_type.value}<br><br>"

        info_text += f"""Game: {pos.game_info.white} vs {pos.game_info.black}<br>
Difficulty: {pos.difficulty}/5<br>
Success rate: {pos.success_rate:.1%}<br>
Reviews: {pos.review_count}<br>
You played: {original_move_san}"""

        # Don't show the correct line - that would spoil the puzzle!
        # The correct_line is still used internally to check moves

        self.position_info.setText(info_text)

    def _reset_ui_for_new_position(self):
        """Reset UI for a new position."""
        self.feedback_label.setText("")
        self.solution_widget.setVisible(False)
        self.solution_btn.setEnabled(True)
        self.next_btn.setEnabled(False)

    def _on_move_made(self, move_uci: str):
        """Handle move made on board."""
        if self.position_solved or not self.current_position or not self.chess_board:
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
        pass
        # """Show the continuation of the correct line if it exists."""
        # if not self.chess_board or not self.current_position.correct_line or len(self.current_position.correct_line) <= 1:
        #     return

        # try:
        #     # Get the current board state (after user's move)
        #     current_board = self.chess_board.board.copy()

        #     # Play the next move in the correct line (opponent's response)
        #     if len(self.current_position.correct_line) > 1:
        #         next_move_san = self.current_position.correct_line[1]

        #         # Convert SAN to move and play it
        #         next_move = current_board.parse_san(next_move_san)
        #         current_board.push(next_move)

        #         # Update the visual board
        #         self.chess_board.set_board(current_board)

        # except (ValueError, chess.InvalidMoveError):
        #     pass  # If we can't parse/play the continuation, just skip it

    def _handle_partial_move(self):
        """Handle a partially correct move."""
        self.feedback_label.setText("Good move, but not the best. Try again!")

    def _handle_incorrect_move(self, time_taken: float, move_uci: str):
        """Handle an incorrect move."""
        # Don't mark as solved - let them keep trying
        self.feedback_label.setText("Incorrect")

        # Reset the board to original position
        if self.chess_board and self.current_position:
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
        """Move to the next position (skip current)."""
        self._load_next_position()

    def _prev_position(self):
        """Go back to previous position."""
        if self.history_index > 0:
            self.history_index -= 1
            self.current_position = self.position_history[self.history_index]
            self.position_solved = False
            self.start_time = datetime.now()

            # Update Previous button state
            self.prev_btn.setEnabled(self.history_index > 0)

            # Set up board
            board = chess.Board(self.current_position.fen)
            if self.chess_board:
                self.chess_board.set_board(board)
                self.chess_board.set_orientation(board.turn == chess.WHITE)
                self.chess_board.set_interactive(True)

            # Update UI
            self._update_position_info()
            self._reset_ui_for_new_position()

    def _show_analysis(self):
        """
        Show analysis view with PGN, pruned to only the mistake and the
        correct tactic, and jump to the tactic's position.
        """
        if not self.current_position:
            QMessageBox.warning(self, "No Position", "No position loaded to analyze.")
            return

        # --- 1. Get Game PGN ---
        pgn_text = self._get_game_pgn()
        if not pgn_text:
            QMessageBox.warning(
                self, "PGN Not Available",
                "PGN data is not available for this position.\n\n"
                "The game PGN might not be stored in the database."
            )
            return

        # Extract tactic info for jumping to the right move
        move_number_to_jump = None
        is_white_to_play = True

        context = self.current_position.context
        match = re.search(r"Move (\d+)", context)
        if match:
            move_number_to_jump = int(match.group(1))

        is_white_to_play = "White" in context

        # Load raw PGN into viewer (no parsing/export overhead)
        if self.pgn_viewer:
            self.pgn_viewer.load_pgn(pgn_text)

            # --- 8. Jump to Move ---
            if move_number_to_jump:
                try:
                    # Calculate ply (half-move) number
                    ply_number = (move_number_to_jump - 1) * 2
                    if not is_white_to_play:
                        ply_number += 1

                    # Tell PGN viewer to jump
                    self.pgn_viewer.goto_ply(ply_number)
                except Exception as e:
                    self.logger.warning(f"Error jumping to move: {e}")

        # Switch to Analysis tab
        self.tab_widget.setCurrentIndex(1)  # Index 1 is Analysis tab

        # Set board to interactive mode for free exploration
        if self.chess_board:
            self.chess_board.set_interactive(True)

    def _get_game_pgn(self) -> str:
        """Get the PGN text for the current game."""
        if not self.current_position or not self.current_position.game_info:
            return ""

        # Try to reconstruct or fetch the PGN
        # For now, we need the game_id to fetch from Lichess or local storage
        game_id = self.current_position.game_info.game_id

        if not game_id:
            return ""

        # Check if we have the PGN stored locally
        # Look in imported_games directory
        from pathlib import Path

        pgn_dir = Path("imported_games")
        if not pgn_dir.exists():
            return ""

        # Search for the game in PGN files by text matching
        for pgn_file in pgn_dir.glob("*.pgn"):
            try:
                with open(pgn_file, 'r', encoding='utf-8') as f:
                    content = f.read()

                    # Split into games (games are separated by blank lines and start with [Event)
                    games = []
                    current_game = []

                    for line in content.split('\n'):
                        # Start of a new game
                        if line.startswith('[Event ') and current_game:
                            games.append('\n'.join(current_game))
                            current_game = [line]
                        else:
                            current_game.append(line)

                    # Don't forget the last game
                    if current_game:
                        games.append('\n'.join(current_game))

                    # Search for the game with matching GameId
                    for game_text in games:
                        if f'[GameId "{game_id}"]' in game_text:
                            return game_text

            except Exception:
                continue

        return ""

    def _on_analysis_position_changed(self, board: chess.Board):
        """Handle position changes in the Analysis tab."""
        if self.chess_board:
            self.chess_board.set_board(board)
            # Keep interactive mode enabled for free exploration
            self.chess_board.set_interactive(True)

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