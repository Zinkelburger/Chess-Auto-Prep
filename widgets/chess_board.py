"""
Unified chess board widget - clean implementation with fixed orientation mapping.
"""
import os
from typing import Optional, Set
from pathlib import Path

import chess
from PySide6.QtWidgets import QWidget
from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QPainter, QColor, QPen, QFont, QMouseEvent

try:
    from PySide6.QtSvg import QSvgRenderer
    from PySide6.QtGui import QPixmap
    SVG_AVAILABLE = True
except ImportError:
    SVG_AVAILABLE = False

from config import PIECES_DIR, LIGHT_SQUARE_COLOR, DARK_SQUARE_COLOR, SELECTED_SQUARE_COLOR, HIGHLIGHT_COLOR


class ChessBoardWidget(QWidget):
    """
    Clean, unified chess board widget with proper coordinate handling.

    Signals:
        move_made(str): Emitted when a move is made (UCI notation)
        square_clicked(int): Emitted when a square is clicked
        piece_selected(int): Emitted when a piece is selected
    """

    # Signals
    move_made = Signal(str)
    square_clicked = Signal(int)
    piece_selected = Signal(int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumSize(400, 400)

        # Board state
        self.board = chess.Board()
        self.flipped = False
        self.interactive = False

        # Selection state
        self.selected_square = None
        self.highlighted_squares = set()

        # Drag and drop state
        self.drag_start_square = None
        self.dragging = False
        self.drag_start_pos = None  # Starting mouse position
        self.current_drag_pos = None  # Current mouse position during drag
        self.dragged_piece = None  # The piece being dragged

        # Piece rendering
        self.piece_images = {}
        self.piece_symbols = {
            chess.WHITE: {
                chess.PAWN: '♙', chess.ROOK: '♖', chess.KNIGHT: '♘',
                chess.BISHOP: '♗', chess.QUEEN: '♕', chess.KING: '♔'
            },
            chess.BLACK: {
                chess.PAWN: '♟', chess.ROOK: '♜', chess.KNIGHT: '♞',
                chess.BISHOP: '♝', chess.QUEEN: '♛', chess.KING: '♚'
            }
        }

        self._load_piece_images()

    def _load_piece_images(self):
        """Load piece SVG images if available."""
        if not SVG_AVAILABLE or not PIECES_DIR.exists():
            return

        piece_files = {
            (chess.WHITE, chess.PAWN): 'wP.svg',
            (chess.WHITE, chess.ROOK): 'wR.svg',
            (chess.WHITE, chess.KNIGHT): 'wN.svg',
            (chess.WHITE, chess.BISHOP): 'wB.svg',
            (chess.WHITE, chess.QUEEN): 'wQ.svg',
            (chess.WHITE, chess.KING): 'wK.svg',
            (chess.BLACK, chess.PAWN): 'bP.svg',
            (chess.BLACK, chess.ROOK): 'bR.svg',
            (chess.BLACK, chess.KNIGHT): 'bN.svg',
            (chess.BLACK, chess.BISHOP): 'bB.svg',
            (chess.BLACK, chess.QUEEN): 'bQ.svg',
            (chess.BLACK, chess.KING): 'bK.svg',
        }

        for (color, piece_type), filename in piece_files.items():
            filepath = PIECES_DIR / filename
            if filepath.exists():
                try:
                    renderer = QSvgRenderer(str(filepath))
                    if renderer.isValid():
                        pixmap = QPixmap(80, 80)
                        pixmap.fill(Qt.transparent)
                        painter = QPainter(pixmap)
                        renderer.render(painter)
                        painter.end()
                        self.piece_images[(color, piece_type)] = pixmap
                except Exception:
                    continue

    def set_board(self, board: chess.Board):
        """Set the board position."""
        self.board = board.copy()
        self.clear_selection()
        self.update()

    def set_orientation(self, white_on_bottom: bool = True):
        """Set board orientation."""
        self.flipped = not white_on_bottom
        self.update()

    def set_interactive(self, interactive: bool):
        """Enable or disable move input."""
        self.interactive = interactive
        if not interactive:
            self.clear_selection()
        self.update()

    def clear_selection(self):
        """Clear current selection and highlights."""
        self.selected_square = None
        self.highlighted_squares.clear()
        self.update()

    def highlight_squares(self, squares: Set[int]):
        """Highlight specific squares."""
        self.highlighted_squares = squares.copy()
        self.update()

    def make_move(self, move_uci: str) -> bool:
        """Make a move on the board."""
        try:
            move = chess.Move.from_uci(move_uci)
            if move in self.board.legal_moves:
                self.board.push(move)
                self.clear_selection()
                return True
        except ValueError:
            pass
        return False

    def _square_from_coords(self, x: int, y: int) -> Optional[int]:
        """Convert mouse coordinates to chess square."""
        size = min(self.width(), self.height())
        square_size = size // 8

        if x < 0 or y < 0 or x >= size or y >= size:
            return None

        col = min(x // square_size, 7)
        row = min(y // square_size, 7)

        # Fixed coordinate mapping - only flip file for black orientation
        if self.flipped:
            col = 7 - col
            # Keep row as-is for flipped orientation
        else:
            row = 7 - row

        return chess.square(col, row)

    def _highlight_legal_moves(self, from_square: int):
        """Highlight legal moves from the given square."""
        self.highlighted_squares.clear()
        for move in self.board.legal_moves:
            if move.from_square == from_square:
                self.highlighted_squares.add(move.to_square)

    def mousePressEvent(self, event: QMouseEvent):
        """Handle mouse press - start drag or click."""
        if not self.interactive:
            return

        square = self._square_from_coords(event.x(), event.y())
        if square is None:
            return

        self.square_clicked.emit(square)
        piece = self.board.piece_at(square)

        # Check if clicking on already selected piece to deselect
        if square == self.selected_square:
            self.clear_selection()
            return

        # Check if we can start a drag from this square
        if piece and piece.color == self.board.turn:
            legal_moves = [move for move in self.board.legal_moves if move.from_square == square]
            if legal_moves:
                # Setup drag state
                self.drag_start_square = square
                self.drag_start_pos = event.pos()
                self.dragged_piece = piece
                self.selected_square = square
                self.piece_selected.emit(square)
                self._highlight_legal_moves(square)
                self.update()
                return

        # Handle click-to-click selection if not starting a drag
        if self.selected_square is None:
            # No piece selected and can't drag from here
            pass
        else:
            # Second click - try to make move
            if square == self.selected_square:
                # Clicked same square - deselect
                self.clear_selection()
            else:
                # Try to make the move
                move = self._create_move(self.selected_square, square)
                if move and move in self.board.legal_moves:
                    self.move_made.emit(move.uci())
                    self.clear_selection()
                else:
                    # Invalid move - clear selection
                    self.clear_selection()

    def mouseMoveEvent(self, event: QMouseEvent):
        """Handle mouse move - track dragging."""
        if not self.interactive or self.drag_start_square is None:
            return

        # Start dragging if we move far enough from start position
        if not self.dragging and self.drag_start_pos is not None:
            distance = (event.pos() - self.drag_start_pos).manhattanLength()
            if distance > 3:  # Start dragging after moving 3 pixels
                self.dragging = True

        # Update drag position and repaint
        if self.dragging:
            self.current_drag_pos = event.pos()
            self.update()

    def mouseReleaseEvent(self, event: QMouseEvent):
        """Handle mouse release - complete drag or click."""
        if not self.interactive:
            return

        if self.dragging and self.drag_start_square is not None:
            # Complete drag operation
            end_square = self._square_from_coords(event.x(), event.y())
            if end_square is not None and end_square != self.drag_start_square:
                # Try to make the move
                move = self._create_move(self.drag_start_square, end_square)
                if move and move in self.board.legal_moves:
                    self.move_made.emit(move.uci())

            # Reset drag state after drag
            self._reset_drag_state()
        else:
            # Simple click - reset drag state but keep selection
            self._reset_drag_state_keep_selection()

    def _reset_drag_state(self):
        """Reset all drag and drop state."""
        self.drag_start_square = None
        self.dragging = False
        self.drag_start_pos = None
        self.current_drag_pos = None
        self.dragged_piece = None
        self.clear_selection()

    def _reset_drag_state_keep_selection(self):
        """Reset drag state but keep current selection for click-to-click moves."""
        self.drag_start_square = None
        self.dragging = False
        self.drag_start_pos = None
        self.current_drag_pos = None
        self.dragged_piece = None
        # Keep self.selected_square and highlighted_squares intact

    def _create_move(self, from_square: int, to_square: int) -> Optional[chess.Move]:
        """Create a move with automatic promotion handling."""
        move = chess.Move(from_square, to_square)

        # Handle pawn promotion
        piece = self.board.piece_at(from_square)
        if (piece and piece.piece_type == chess.PAWN and
            ((piece.color == chess.WHITE and chess.square_rank(to_square) == 7) or
             (piece.color == chess.BLACK and chess.square_rank(to_square) == 0))):
            move.promotion = chess.QUEEN

        return move

    def paintEvent(self, event):
        """Paint the chess board and pieces."""
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        # Calculate square size
        size = min(self.width(), self.height())
        square_size = size // 8

        # Draw board squares
        for row in range(8):
            for col in range(8):
                x = col * square_size
                y = row * square_size

                # Calculate chess square - fixed coordinate mapping
                if self.flipped:
                    square = chess.square(7 - col, row)
                else:
                    square = chess.square(col, 7 - row)

                # Determine square color
                if (row + col) % 2 == 0:
                    color = QColor(*LIGHT_SQUARE_COLOR)
                else:
                    color = QColor(*DARK_SQUARE_COLOR)

                # Highlight squares
                if square == self.selected_square:
                    color = QColor(*SELECTED_SQUARE_COLOR)
                elif square in self.highlighted_squares:
                    painter.fillRect(x, y, square_size, square_size, color)
                    painter.fillRect(x, y, square_size, square_size, QColor(*HIGHLIGHT_COLOR))
                    self._draw_piece(painter, square, x, y, square_size)
                    continue

                painter.fillRect(x, y, square_size, square_size, color)
                self._draw_piece(painter, square, x, y, square_size)

        # Draw the dragged piece at cursor position
        if self.dragging and self.dragged_piece and self.current_drag_pos:
            self._draw_dragged_piece(painter, square_size)

    def _draw_piece(self, painter: QPainter, square: int, x: int, y: int, square_size: int):
        """Draw a piece on the given square."""
        piece = self.board.piece_at(square)
        if not piece:
            return

        # Skip drawing if this piece is being dragged
        if self.dragging and square == self.drag_start_square:
            return

        piece_key = (piece.color, piece.piece_type)

        # Try SVG images first
        if piece_key in self.piece_images:
            piece_pixmap = self.piece_images[piece_key]
            scaled_pixmap = piece_pixmap.scaled(
                square_size - 4, square_size - 4,
                Qt.KeepAspectRatio, Qt.SmoothTransformation
            )
            piece_x = x + (square_size - scaled_pixmap.width()) // 2
            piece_y = y + (square_size - scaled_pixmap.height()) // 2
            painter.drawPixmap(piece_x, piece_y, scaled_pixmap)
        else:
            # Fallback to Unicode symbols
            symbol = self.piece_symbols[piece.color][piece.piece_type]
            font = QFont()
            font.setPointSize(square_size // 3)
            painter.setFont(font)
            painter.setPen(QColor(0, 0, 0))
            painter.drawText(x, y, square_size, square_size, Qt.AlignCenter, symbol)

    def _draw_dragged_piece(self, painter: QPainter, square_size: int):
        """Draw the piece being dragged at the cursor position."""
        if not self.dragged_piece or not self.current_drag_pos:
            return

        piece = self.dragged_piece
        piece_key = (piece.color, piece.piece_type)

        # Center the piece on the cursor
        piece_size = square_size  # Keep same size while dragging
        x = self.current_drag_pos.x() - piece_size // 2
        y = self.current_drag_pos.y() - piece_size // 2

        # Try SVG images first
        if piece_key in self.piece_images:
            piece_pixmap = self.piece_images[piece_key]
            scaled_pixmap = piece_pixmap.scaled(
                piece_size, piece_size,
                Qt.KeepAspectRatio, Qt.SmoothTransformation
            )
            painter.drawPixmap(x, y, scaled_pixmap)
        else:
            # Fallback to Unicode symbols
            symbol = self.piece_symbols[piece.color][piece.piece_type]
            font = QFont()
            font.setPointSize(piece_size // 3)
            painter.setFont(font)
            painter.setPen(QColor(0, 0, 0))
            painter.drawText(x, y, piece_size, piece_size, Qt.AlignCenter, symbol)