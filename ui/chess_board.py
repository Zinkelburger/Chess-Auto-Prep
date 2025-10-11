"""
Chess board widget for displaying chess positions.
"""
import os
from PySide6.QtWidgets import QWidget
from PySide6.QtCore import Qt
from PySide6.QtGui import QPainter, QColor
try:
    from PySide6.QtSvg import QSvgRenderer
    from PySide6.QtGui import QPixmap
    SVG_AVAILABLE = True
except ImportError:
    SVG_AVAILABLE = False

import chess


class ChessBoardWidget(QWidget):
    """Widget for displaying a chess board with pieces."""

    def __init__(self):
        super().__init__()
        self.board = chess.Board()
        self.setMinimumSize(400, 400)
        self.piece_images = {}
        self.piece_symbols = {
            (chess.WHITE, chess.PAWN): '♙',
            (chess.WHITE, chess.ROOK): '♖',
            (chess.WHITE, chess.KNIGHT): '♘',
            (chess.WHITE, chess.BISHOP): '♗',
            (chess.WHITE, chess.QUEEN): '♕',
            (chess.WHITE, chess.KING): '♔',
            (chess.BLACK, chess.PAWN): '♟',
            (chess.BLACK, chess.ROOK): '♜',
            (chess.BLACK, chess.KNIGHT): '♞',
            (chess.BLACK, chess.BISHOP): '♝',
            (chess.BLACK, chess.QUEEN): '♛',
            (chess.BLACK, chess.KING): '♚',
        }
        self._load_piece_images()

    def _load_piece_images(self):
        """Load piece images from SVG files."""
        piece_files = {
            (chess.WHITE, chess.PAWN): 'pieces/wP.svg',
            (chess.WHITE, chess.ROOK): 'pieces/wR.svg',
            (chess.WHITE, chess.KNIGHT): 'pieces/wN.svg',
            (chess.WHITE, chess.BISHOP): 'pieces/wB.svg',
            (chess.WHITE, chess.QUEEN): 'pieces/wQ.svg',
            (chess.WHITE, chess.KING): 'pieces/wK.svg',
            (chess.BLACK, chess.PAWN): 'pieces/bP.svg',
            (chess.BLACK, chess.ROOK): 'pieces/bR.svg',
            (chess.BLACK, chess.KNIGHT): 'pieces/bN.svg',
            (chess.BLACK, chess.BISHOP): 'pieces/bB.svg',
            (chess.BLACK, chess.QUEEN): 'pieces/bQ.svg',
            (chess.BLACK, chess.KING): 'pieces/bK.svg',
        }

        if not SVG_AVAILABLE:
            return

        for (color, piece_type), filename in piece_files.items():
            if os.path.exists(filename):
                try:
                    renderer = QSvgRenderer(filename)
                    if renderer.isValid():
                        pixmap = QPixmap(80, 80)
                        pixmap.fill(Qt.transparent)
                        painter = QPainter(pixmap)
                        renderer.render(painter)
                        painter.end()
                        self.piece_images[(color, piece_type)] = pixmap
                except Exception:
                    pass

    def set_board(self, board: chess.Board):
        """Set the board position to display."""
        self.board = board
        self.update()

    def paintEvent(self, event):
        """Paint the chess board and pieces."""
        painter = QPainter(self)

        # Calculate square size
        size = min(self.width(), self.height())
        square_size = size // 8

        # Draw board
        for row in range(8):
            for col in range(8):
                x = col * square_size
                y = row * square_size

                # Alternate colors
                if (row + col) % 2 == 0:
                    painter.fillRect(x, y, square_size, square_size, QColor(240, 217, 181))
                else:
                    painter.fillRect(x, y, square_size, square_size, QColor(181, 136, 99))

                # Draw piece
                square = chess.square(col, 7-row)
                piece = self.board.piece_at(square)
                if piece:
                    piece_key = (piece.color, piece.piece_type)
                    if piece_key in self.piece_images:
                        # Use SVG images
                        piece_pixmap = self.piece_images[piece_key]
                        scaled_pixmap = piece_pixmap.scaled(
                            square_size - 4, square_size - 4,
                            Qt.KeepAspectRatio, Qt.SmoothTransformation
                        )
                        piece_x = x + (square_size - scaled_pixmap.width()) // 2
                        piece_y = y + (square_size - scaled_pixmap.height()) // 2
                        painter.drawPixmap(piece_x, piece_y, scaled_pixmap)
                    elif piece_key in self.piece_symbols:
                        # Fallback to Unicode symbols
                        symbol = self.piece_symbols[piece_key]
                        font = painter.font()
                        font.setPointSize(square_size // 2)
                        painter.setFont(font)
                        painter.setPen(QColor(0, 0, 0))
                        painter.drawText(x, y, square_size, square_size, Qt.AlignCenter, symbol)