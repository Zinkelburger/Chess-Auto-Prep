#!/usr/bin/env python3
"""
Simple test for promotion functionality without full GUI.
"""
import chess

def test_promotion_detection_logic():
    """Test the promotion detection logic from chess_board.py"""

    def is_promotion_move(board, from_square, to_square):
        """Replicate the logic from chess_board.py"""
        piece = board.piece_at(from_square)
        return (piece and piece.piece_type == chess.PAWN and
                ((piece.color == chess.WHITE and chess.square_rank(to_square) == 7) or
                 (piece.color == chess.BLACK and chess.square_rank(to_square) == 0)))

    def create_move(board, from_square, to_square, promotion_piece=None):
        """Replicate move creation logic"""
        move = chess.Move(from_square, to_square)

        if is_promotion_move(board, from_square, to_square):
            if promotion_piece is None:
                return None  # Would trigger promotion selector
            move.promotion = promotion_piece

        return move

    print("Testing promotion detection logic:")

    # Test white pawn promotion
    board = chess.Board("8/P7/8/8/8/8/8/8 w - - 0 1")
    print(f"\nWhite pawn on a7: {board.fen()}")

    from_sq = chess.A7
    to_sq = chess.A8

    print(f"Move from {chess.square_name(from_sq)} to {chess.square_name(to_sq)}")
    print(f"Is promotion: {is_promotion_move(board, from_sq, to_sq)}")

    # Test without promotion piece (should return None)
    move = create_move(board, from_sq, to_sq)
    print(f"Move without promotion piece: {move}")

    # Test with promotion pieces
    for piece_type, name in [(chess.QUEEN, "Queen"), (chess.ROOK, "Rook"),
                             (chess.BISHOP, "Bishop"), (chess.KNIGHT, "Knight")]:
        move = create_move(board, from_sq, to_sq, piece_type)
        print(f"Move with {name}: {move.uci() if move else None}")
        if move:
            print(f"  Legal: {move in board.legal_moves}")

    # Test black pawn promotion
    board = chess.Board("8/8/8/8/8/8/p7/8 b - - 0 1")
    print(f"\nBlack pawn on a2: {board.fen()}")

    from_sq = chess.A2
    to_sq = chess.A1

    print(f"Move from {chess.square_name(from_sq)} to {chess.square_name(to_sq)}")
    print(f"Is promotion: {is_promotion_move(board, from_sq, to_sq)}")

    # Test with queen promotion
    move = create_move(board, from_sq, to_sq, chess.QUEEN)
    print(f"Black queen promotion: {move.uci() if move else None}")
    if move:
        print(f"  Legal: {move in board.legal_moves}")

    # Test non-promotion move
    board = chess.Board()  # Starting position
    from_sq = chess.E2
    to_sq = chess.E4

    print(f"\nNormal pawn move e2-e4:")
    print(f"Is promotion: {is_promotion_move(board, from_sq, to_sq)}")
    move = create_move(board, from_sq, to_sq)
    print(f"Move: {move.uci() if move else None}")

if __name__ == "__main__":
    test_promotion_detection_logic()
    print("\nPromotion logic test completed!")