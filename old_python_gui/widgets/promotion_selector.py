"""
Promotion piece selector widget with visual piece selection.
"""
from typing import Optional

import chess
from PySide6.QtWidgets import QWidget, QHBoxLayout, QVBoxLayout, QLabel, QPushButton
from PySide6.QtCore import Qt, Signal, QSize
from PySide6.QtGui import QPainter, QColor, QPen, QFont

try:
    from PySide6.QtSvg import QSvgRenderer
    from PySide6.QtGui import QPixmap
    SVG_AVAILABLE = True
except ImportError:
    SVG_AVAILABLE = False

from config import PIECES_DIR, LIGHT_SQUARE_COLOR


class PromotionPieceButton(QPushButton):
    """A button showing a chess piece for promotion selection."""

    piece_selected = Signal(int)  # Emits the piece type (QUEEN, ROOK, etc.)

    def __init__(self, piece_type: int, color: bool, parent=None):
        super().__init__(parent)
        self.piece_type = piece_type
        self.color = color
        self.piece_pixmap = None

        # Button styling
        self.setFixedSize(60, 60)
        self.setStyleSheet("""
            QPushButton {
                border: 2px solid #888;
                border-radius: 8px;
                background-color: rgb(%d, %d, %d);
            }
            QPushButton:hover {
                border: 3px solid #444;
                background-color: #f0f0f0;
            }
            QPushButton:pressed {
                border: 3px solid #000;
                background-color: #e0e0e0;
            }
        """ % LIGHT_SQUARE_COLOR)

        # Unicode fallback symbols
        self.piece_symbols = {
            chess.WHITE: {
                chess.QUEEN: '♕', chess.ROOK: '♖',
                chess.KNIGHT: '♘', chess.BISHOP: '♗'
            },
            chess.BLACK: {
                chess.QUEEN: '♛', chess.ROOK: '♜',
                chess.KNIGHT: '♞', chess.BISHOP: '♝'
            }
        }

        self._load_piece_image()
        self.clicked.connect(lambda: self.piece_selected.emit(self.piece_type))

    def _load_piece_image(self):
        """Load the piece SVG image."""
        if not SVG_AVAILABLE or not PIECES_DIR.exists():
            return

        piece_files = {
            (chess.WHITE, chess.QUEEN): 'wQ.svg',
            (chess.WHITE, chess.ROOK): 'wR.svg',
            (chess.WHITE, chess.KNIGHT): 'wN.svg',
            (chess.WHITE, chess.BISHOP): 'wB.svg',
            (chess.BLACK, chess.QUEEN): 'bQ.svg',
            (chess.BLACK, chess.ROOK): 'bR.svg',
            (chess.BLACK, chess.KNIGHT): 'bN.svg',
            (chess.BLACK, chess.BISHOP): 'bB.svg',
        }

        filename = piece_files.get((self.color, self.piece_type))
        if not filename:
            return

        filepath = PIECES_DIR / filename
        if filepath.exists():
            try:
                renderer = QSvgRenderer(str(filepath))
                if renderer.isValid():
                    pixmap = QPixmap(50, 50)
                    pixmap.fill(Qt.transparent)
                    painter = QPainter(pixmap)
                    renderer.render(painter)
                    painter.end()
                    self.piece_pixmap = pixmap
            except Exception:
                pass

    def paintEvent(self, event):
        """Custom paint to draw the piece."""
        super().paintEvent(event)

        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        # Draw piece image or Unicode fallback
        if self.piece_pixmap:
            # Center the piece image
            x = (self.width() - self.piece_pixmap.width()) // 2
            y = (self.height() - self.piece_pixmap.height()) // 2
            painter.drawPixmap(x, y, self.piece_pixmap)
        else:
            # Fallback to Unicode symbol
            symbol = self.piece_symbols[self.color][self.piece_type]
            font = QFont()
            font.setPointSize(24)
            painter.setFont(font)
            painter.setPen(QColor(0, 0, 0))
            painter.drawText(self.rect(), Qt.AlignCenter, symbol)


class PromotionSelector(QWidget):
    """
    Widget for selecting promotion piece with visual piece buttons.
    Shows as an overlay on the chess board.
    """

    piece_selected = Signal(int)  # Emits the selected piece type
    selection_cancelled = Signal()  # Emitted if user cancels

    def __init__(self, color: bool, parent=None):
        super().__init__(parent)
        self.color = color
        self.selected_piece = None

        # Widget styling
        self.setStyleSheet("""
            QWidget {
                background-color: rgba(240, 240, 240, 240);
                border: 2px solid #444;
                border-radius: 12px;
            }
        """)

        # Set a fixed size that looks good
        self.setFixedSize(280, 120)

        self._setup_ui()

        # Make the widget modal-like
        self.setWindowFlags(Qt.Tool | Qt.FramelessWindowHint)
        self.setAttribute(Qt.WA_DeleteOnClose)

    def _setup_ui(self):
        """Setup the UI with piece selection buttons."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(8)

        # Title
        title = QLabel("Promote to:")
        title.setAlignment(Qt.AlignCenter)
        title.setFont(QFont("Arial", 12, QFont.Bold))
        layout.addWidget(title)

        # Piece buttons in a horizontal layout
        buttons_layout = QHBoxLayout()
        buttons_layout.setSpacing(8)

        # Create buttons for each promotion piece (Queen, Rook, Bishop, Knight)
        piece_types = [chess.QUEEN, chess.ROOK, chess.BISHOP, chess.KNIGHT]

        for piece_type in piece_types:
            button = PromotionPieceButton(piece_type, self.color)
            button.piece_selected.connect(self._on_piece_selected)
            buttons_layout.addWidget(button)

        layout.addLayout(buttons_layout)

    def _on_piece_selected(self, piece_type: int):
        """Handle piece selection."""
        self.selected_piece = piece_type
        self.piece_selected.emit(piece_type)
        self.close()

    def keyPressEvent(self, event):
        """Handle key presses for quick selection."""
        key = event.key()

        # Quick selection with keyboard
        if key == Qt.Key_Q:
            self._on_piece_selected(chess.QUEEN)
        elif key == Qt.Key_R:
            self._on_piece_selected(chess.ROOK)
        elif key == Qt.Key_B:
            self._on_piece_selected(chess.BISHOP)
        elif key == Qt.Key_N or key == Qt.Key_K:  # K for Knight since N might be confusing
            self._on_piece_selected(chess.KNIGHT)
        elif key == Qt.Key_Escape:
            self.selection_cancelled.emit()
            self.close()
        else:
            super().keyPressEvent(event)

    def show_at_position(self, global_pos):
        """Show the selector at a specific global position."""
        # Position the widget near the given position but ensure it stays on screen
        screen_geometry = self.screen().geometry()

        x = global_pos.x() - self.width() // 2
        y = global_pos.y() - self.height() // 2

        # Keep within screen bounds
        x = max(10, min(x, screen_geometry.width() - self.width() - 10))
        y = max(10, min(y, screen_geometry.height() - self.height() - 10))

        self.move(x, y)
        self.show()
        self.raise_()
        self.setFocus()