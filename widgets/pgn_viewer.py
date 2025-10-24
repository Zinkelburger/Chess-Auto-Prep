"""
PGN viewer widget with move navigation and variation support.
"""
import io
import chess
import chess.pgn
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QTextBrowser, QHBoxLayout,
    QPushButton, QLabel
)
from PySide6.QtCore import Signal, Qt
from PySide6.QtGui import QTextCursor, QTextCharFormat, QColor, QFont


class PGNViewerWidget(QWidget):
    """
    PGN viewer with clickable moves and variation support.
    """

    position_changed = Signal(object)  # Emits chess.Board

    def __init__(self, parent=None):
        super().__init__(parent)
        self.game = None
        self.current_node = None
        self.board = chess.Board()
        self._setup_ui()

    def _setup_ui(self):
        """Setup the UI."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(5, 5, 5, 5)

        # Game info
        self.info_label = QLabel("")
        self.info_label.setWordWrap(True)
        layout.addWidget(self.info_label)

        # PGN display
        self.pgn_browser = QTextBrowser()
        self.pgn_browser.setOpenLinks(False)
        self.pgn_browser.anchorClicked.connect(self._on_move_clicked)
        layout.addWidget(self.pgn_browser)

        # Navigation buttons
        nav_layout = QHBoxLayout()
        self.start_btn = QPushButton("⏮ Start")
        self.back_btn = QPushButton("◀ Back")
        self.forward_btn = QPushButton("Forward ▶")
        self.end_btn = QPushButton("End ⏭")

        self.start_btn.clicked.connect(self._go_to_start)
        self.back_btn.clicked.connect(self._go_back)
        self.forward_btn.clicked.connect(self._go_forward)
        self.end_btn.clicked.connect(self._go_to_end)

        nav_layout.addWidget(self.start_btn)
        nav_layout.addWidget(self.back_btn)
        nav_layout.addWidget(self.forward_btn)
        nav_layout.addWidget(self.end_btn)
        layout.addLayout(nav_layout)

        self._update_nav_buttons()

    def load_pgn(self, pgn_text: str):
        """Load a PGN game."""
        try:
            self.game = chess.pgn.read_game(io.StringIO(pgn_text))
            if self.game:
                self.current_node = self.game
                self.board = self.game.board()
                self._display_pgn()
                self._update_info()
                self._update_nav_buttons()
                self.position_changed.emit(self.board.copy())
        except Exception as e:
            self.pgn_browser.setPlainText(f"Error loading PGN: {e}")

    def _display_pgn(self):
        """Display PGN with clickable moves."""
        if not self.game:
            return

        html = "<style>"
        html += "a { text-decoration: none; color: #5eb8ff; }"
        html += "a:hover { background-color: #e0e0e0; }"
        html += ".current { background-color: #ffff00; font-weight: bold; }"
        html += ".variation { color: #999; margin-left: 20px; }"
        html += "</style>"

        html += "<div style='font-family: monospace; font-size: 12pt;'>"
        html += self._format_node(self.game, move_number=1)
        html += "</div>"

        self.pgn_browser.setHtml(html)

    def _format_nags(self, nags) -> str:
        """Convert NAG numbers to symbols like ?, ??, !, etc."""
        nag_symbols = {
            1: "!",    # good move
            2: "?",    # mistake
            3: "!!",   # brilliant move
            4: "??",   # blunder
            5: "!?",   # interesting move
            6: "?!",   # dubious move
        }
        result = ""
        for nag in nags:
            if nag in nag_symbols:
                result += nag_symbols[nag]
        return result

    def _format_node(self, node, move_number: int = 1, is_variation: bool = False) -> str:
        """Recursively format a game node with variations."""
        html = ""
        board = node.board()

        for child in node.variations:
            move = child.move
            san = board.san(move)

            # Add NAG symbols (?, ??, !, etc.)
            san += self._format_nags(child.nags)

            # Show move number for white's moves
            if board.turn == chess.WHITE:
                html += f"{move_number}. "

            # Create clickable link
            move_id = id(child)
            css_class = "current" if child == self.current_node else ""
            if is_variation:
                css_class += " variation"

            html += f'<a href="#{move_id}" class="{css_class}">{san}</a> '

            # Add comment if exists
            if child.comment:
                html += f'<span style="color: green;">({child.comment})</span> '

            # Handle variations
            if len(child.variations) > 1:
                main_line = child.variations[0]
                html += self._format_node(
                    main_line,
                    move_number=move_number + 1 if board.turn == chess.BLACK else move_number,
                    is_variation=False
                )

                # Show side variations
                for variation in child.variations[1:]:
                    html += '<span class="variation">( '
                    html += self._format_node(
                        variation,
                        move_number=move_number,
                        is_variation=True
                    )
                    html += ') </span>'
            else:
                # Continue main line
                if child.variations:
                    next_move_number = move_number + 1 if board.turn == chess.BLACK else move_number
                    html += self._format_node(child, next_move_number, is_variation)

            break  # Only process first variation in this call

        return html

    def _on_move_clicked(self, url):
        """Handle move click."""
        # Find the node by ID
        move_id = int(url.toString().replace("#", ""))
        node = self._find_node_by_id(self.game, move_id)

        if node:
            self.current_node = node
            self.board = node.board()
            self._display_pgn()
            self._update_nav_buttons()
            self.position_changed.emit(self.board.copy())

    def _find_node_by_id(self, node, target_id):
        """Recursively find a node by its ID."""
        if id(node) == target_id:
            return node

        for child in node.variations:
            result = self._find_node_by_id(child, target_id)
            if result:
                return result

        return None

    def _update_info(self):
        """Update game information display."""
        if not self.game:
            return

        headers = self.game.headers
        info = f"<b>{headers.get('White', '?')} vs {headers.get('Black', '?')}</b><br>"
        info += f"{headers.get('Event', '')} • {headers.get('Date', '')} • {headers.get('Result', '')}"
        self.info_label.setText(info)

    def _update_nav_buttons(self):
        """Update navigation button states."""
        has_prev = self.current_node is not None and self.current_node.parent is not None
        has_next = self.current_node is not None and bool(self.current_node.variations)

        self.start_btn.setEnabled(has_prev)
        self.back_btn.setEnabled(has_prev)
        self.forward_btn.setEnabled(has_next)
        self.end_btn.setEnabled(has_next)

    def _go_to_start(self):
        """Go to start of game."""
        if self.game:
            self.current_node = self.game
            self.board = self.game.board()
            self._display_pgn()
            self._update_nav_buttons()
            self.position_changed.emit(self.board.copy())

    def _go_back(self):
        """Go back one move."""
        if self.current_node and self.current_node.parent:
            self.current_node = self.current_node.parent
            self.board = self.current_node.board()
            self._display_pgn()
            self._update_nav_buttons()
            self.position_changed.emit(self.board.copy())

    def _go_forward(self):
        """Go forward one move."""
        if self.current_node and self.current_node.variations:
            self.current_node = self.current_node.variations[0]
            self.board = self.current_node.board()
            self._display_pgn()
            self._update_nav_buttons()
            self.position_changed.emit(self.board.copy())

    def _go_to_end(self):
        """Go to end of game."""
        if self.current_node:
            while self.current_node.variations:
                self.current_node = self.current_node.variations[0]
            self.board = self.current_node.board()
            self._display_pgn()
            self._update_nav_buttons()
            self.position_changed.emit(self.board.copy())

    def goto_ply(self, ply_number: int):
        """
        Navigate to a specific ply (half-move) in the game.
        Ply 0 = starting position
        Ply 1 = after White's first move
        Ply 2 = after Black's first move
        etc.
        """
        if not self.game:
            return

        # Start at the beginning
        self.current_node = self.game
        self.board = self.game.board()

        # Navigate forward ply_number times along the main line
        for i in range(ply_number):
            if self.current_node.variations:
                self.current_node = self.current_node.variations[0]
                self.board = self.current_node.board()
            else:
                # Reached end of game before target ply
                break

        # Update display
        self._display_pgn()
        self._update_nav_buttons()
        self.position_changed.emit(self.board.copy())
