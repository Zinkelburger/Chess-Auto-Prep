#!/usr/bin/env python3
"""
Test script for pawn promotion functionality.
"""
import chess

def test_promotion_detection():
    """Test promotion move detection."""

    # Test position with white pawn about to promote
    board = chess.Board("8/P7/8/8/8/8/8/8 w - - 0 1")

    print("Testing promotion detection:")
    print(f"Board: {board.fen()}")
    print(f"White pawn on a7, promoting to a8")

    # Create a promotion move
    move = chess.Move.from_uci("a7a8q")  # Promote to queen
    print(f"Move: {move.uci()}")
    print(f"Is promotion: {move.promotion is not None}")
    print(f"Promotion piece: {move.promotion}")

    # Test different promotion pieces
    promotion_pieces = {
        chess.QUEEN: "Queen",
        chess.ROOK: "Rook",
        chess.BISHOP: "Bishop",
        chess.KNIGHT: "Knight"
    }

    print("\nTesting different promotion pieces:")
    for piece_type, piece_name in promotion_pieces.items():
        move = chess.Move(chess.A7, chess.A8, promotion=piece_type)
        print(f"  {piece_name}: {move.uci()}")
        print(f"    Legal: {move in board.legal_moves}")

    # Test black pawn promotion
    board_black = chess.Board("8/8/8/8/8/8/p7/8 b - - 0 1")
    print(f"\nBlack pawn promotion test:")
    print(f"Board: {board_black.fen()}")

    for piece_type, piece_name in promotion_pieces.items():
        move = chess.Move(chess.A2, chess.A1, promotion=piece_type)
        print(f"  {piece_name}: {move.uci()}")
        print(f"    Legal: {move in board_black.legal_moves}")

def test_promotion_in_game():
    """Test promotion in a real game context."""

    print("\n" + "="*50)
    print("Testing promotion in game context")
    print("="*50)

    # Load a position where promotion is possible
    board = chess.Board()

    # Play moves to get to a promotion position
    moves = [
        "e4", "e5", "Nf3", "Nc6", "Bc4", "Bc5", "O-O", "d6",
        "c3", "f5", "d4", "fxe4", "dxc5", "exf3", "Qxf3", "dxc5",
        "Be3", "Qf6", "Qxf6", "Nxf6", "Bxc5", "b6", "Be3", "Bb7",
        "a4", "a5", "b4", "axb4", "cxb4", "O-O-O", "a5", "bxa5",
        "Rxa5", "Rxa5", "bxa5", "Nd4", "Bd2", "Nf5", "a6", "Bxg2",
        "axb7", "Kxb7"
    ]

    print("Playing game moves...")
    for i, move_san in enumerate(moves):
        try:
            move = board.parse_san(move_san)
            board.push(move)
            if i % 8 == 7:  # Print position every 8 moves
                print(f"After move {i+1}: {board.fen()[:20]}...")
        except Exception as e:
            print(f"Error playing move {move_san}: {e}")
            break

    print(f"\nFinal position: {board.fen()}")
    print(f"Turn: {'White' if board.turn else 'Black'}")

    # Check for any pawns that can promote
    for square in chess.SQUARES:
        piece = board.piece_at(square)
        if piece and piece.piece_type == chess.PAWN:
            rank = chess.square_rank(square)
            if (piece.color == chess.WHITE and rank == 6) or (piece.color == chess.BLACK and rank == 1):
                print(f"Pawn ready to promote: {chess.square_name(square)} ({piece})")

if __name__ == "__main__":
    test_promotion_detection()
    test_promotion_in_game()
    print("\nPromotion tests completed!")