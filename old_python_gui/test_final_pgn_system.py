#!/usr/bin/env python3
"""
Test the complete updated PGN system with comment filtering.
"""

from core.pgn_processor import PGNProcessor

def test_complete_system():
    """Test the complete PGN system with comment filtering."""

    # User's game with eval/clock comments
    user_pgn = '''[Event "Live Chess"]
[Site "Chess.com"]
[Date "2025.10.18"]
[Round "-"]
[White "ibrahimahmedElgen"]
[Black "BigManArkhangelsk"]
[Result "1-0"]

1. d4 { [%eval 0.17] [%clk 0:03:00] } 1... Nf6 { [%eval 0.19] [%clk 0:02:59] } 2. c4 { [%eval 0.18] [%clk 0:03:01] } 2... c5 { [%eval 0.56] [%clk 0:02:58] } { A56 Benoni Defense } 3. e3 { [%eval 0.08] [%clk 0:03:02] } 3... g6 { [%eval 0.25] [%clk 0:02:50] } 4. Nc3 { [%eval 0.21] [%clk 0:03:01] } 4... Bg7 { [%eval 0.2] [%clk 0:02:51] } 5. Nf3 { [%eval 0.0] [%clk 0:03:01] } 5... O-O { [%eval 0.36] [%clk 0:02:52] } 6. Be2 { [%eval -0.09] [%clk 0:03:01] } 6... b6?! { (-0.09 → 0.53) Inaccuracy. cxd4 was best. } { [%eval 0.53] [%clk 0:02:43] } (6... cxd4 7. Qxd4 d5 8. Nxd5 Nc6 9. Qd1 Be6 10. Nxf6+ Bxf6 11. O-O) 7. d5 { [%eval 0.48] [%clk 0:03:00] } 7... d6 { [%eval 0.57] [%clk 0:02:39] } 8. e4 { [%eval 0.58] [%clk 0:02:59] } 8... e6 { [%eval 0.62] [%clk 0:02:36] } 9. dxe6?! { (0.62 → 0.01) Inaccuracy. O-O was best. } { [%eval 0.01] [%clk 0:02:57] } 9... fxe6 { [%eval 0.0] [%clk 0:02:30] } 10. Bg5 { [%eval 0.01] [%clk 0:02:58] } 10... h6 { [%eval 0.18] [%clk 0:02:23] } 11. Bh4 { [%eval -0.28] [%clk 0:02:57] } 11... Qe7?? { (-0.28 → 1.60) Blunder. Nc6 was best. } { [%eval 1.6] [%clk 0:02:15] } 12. e5 { A tactical blow! } 12... Bb7? { (1.60 → 2.95) Mistake. g5 was best. } { [%eval 2.95] [%clk 0:01:54] } 1-0'''

    print("=== Testing Complete PGN System ===")

    processor = PGNProcessor()
    game_data = processor.parse_pgn(user_pgn)

    if not game_data:
        print("❌ Failed to parse PGN")
        return

    print("✅ Game parsed successfully")

    print("\n=== Moves with Comments (After Filtering) ===")
    moves_with_comments = []
    for i, move in enumerate(game_data.main_line):
        if move.comments:
            moves_with_comments.append((i, move))

    print(f"Found {len(moves_with_comments)} moves with meaningful comments:")
    for i, move in moves_with_comments:
        print(f"  Move {move.move_number}: {move.san} - '{move.comment_text}'")

    print("\n=== Moves with NAG Annotations ===")
    nag_moves = []
    for i, move in enumerate(game_data.main_line):
        if move.nags:
            nag_moves.append((i, move))

    print(f"Found {len(nag_moves)} moves with NAGs:")
    for i, move in nag_moves:
        print(f"  Move {move.move_number}: {move.san} {move.nags}")

    print("\n=== Expected Results ===")
    print("✅ All eval/clock comments should be filtered out")
    print("✅ Opening names like 'A56 Benoni Defense' should be kept")
    print("✅ Tactical comments like 'A tactical blow!' should be kept")
    print("✅ NAG moves like 'b6?!', 'dxe6?!', 'Qe7??' should all display")

    print("\n=== Formatted Game (Clean) ===")
    formatted = processor.format_moves_with_annotations(game_data.main_line)
    print(formatted)

if __name__ == "__main__":
    test_complete_system()