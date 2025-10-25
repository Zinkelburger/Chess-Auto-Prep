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
from PySide6.QtCore import Signal


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

    def _filter_comment(self, comment: str) -> str:
        """Filter out eval and clock comments, keeping only meaningful text."""
        if not comment:
            return ""

        import re

        # Remove eval comments like [%eval 0.17] or [%eval -1.25]
        comment = re.sub(r'\[%eval [^\]]+\]', '', comment)

        # Remove clock comments like [%clk 0:03:00]
        comment = re.sub(r'\[%clk [^\]]+\]', '', comment)

        # Remove engine evaluation text like "(0.62 → 0.01)"
        comment = re.sub(r'\([+-]?\d+\.?\d*\s*[→-]\s*[+-]?\d+\.?\d*\)', '', comment)

        # Remove phrases for inaccuracies, mistakes and blunders (keep only meaningful content)
        comment = re.sub(r'(Inaccuracy|Mistake|Blunder|Good move|Excellent move|Best move)\.[^.]*\.', '', comment)

        # Remove "was best" phrases
        comment = re.sub(r'[A-Za-z0-9+#-]+\s+was best\.?', '', comment)

        # Clean up extra whitespace
        comment = re.sub(r'\s+', ' ', comment).strip()

        # Return None if comment is now empty or just punctuation
        if not comment or comment in '.,;!?':
            return ""

        return comment

    def _format_node(self, node, move_number: int = 1, is_variation: bool = False) -> str:
        """Recursively format a game node with variations."""
        html = ""
        board = node.board()
        current_node = node
        current_move_number = move_number

        # Traverse the main line without breaking
        while current_node.variations:
            child = current_node.variations[0]  # Main line
            move = child.move
            san = board.san(move)

            # Add NAG symbols (?, ??, !, etc.)
            san += self._format_nags(child.nags)

            # Show move number for white's moves
            if board.turn == chess.WHITE:
                html += f"{current_move_number}. "

            # Create clickable link
            move_id = id(child)
            css_class = "current" if child == self.current_node else ""
            if is_variation:
                css_class += " variation"

            html += f'<a href="#{move_id}" class="{css_class}">{san}</a> '

            # Add comment if exists (but filter out eval/clock comments)
            if child.comment:
                filtered_comment = self._filter_comment(child.comment)
                if filtered_comment:
                    html += f'<span style="color: green;">({filtered_comment})</span> '

            # Handle side variations (alternatives to this move)
            if len(current_node.variations) > 1:
                for variation in current_node.variations[1:]:
                    html += '<span class="variation">( '
                    html += self._format_node(
                        variation,
                        move_number=current_move_number,
                        is_variation=True
                    )
                    html += ') </span>'

            # Update for next iteration
            if board.turn == chess.BLACK:
                current_move_number += 1

            board.push(move)
            current_node = child

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
        for _ in range(ply_number):
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
