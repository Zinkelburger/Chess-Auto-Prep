#!/usr/bin/env python3
"""
Debug script to test PGN parsing with the user's actual game.
"""

from core.pgn_processor import PGNProcessor

def debug_user_game():
    """Debug the specific game that's having issues."""

    # User's game with NAG issues
    user_pgn = '''[Event "Live Chess"]
[Site "Chess.com"]
[Date "2025.10.18"]
[Round "-"]
[White "ibrahimahmedElgen"]
[Black "BigManArkhangelsk"]
[Result "1-0"]
[GameId "Aq9fm8DR"]
[WhiteElo "2162"]
[BlackElo "2045"]
[Variant "Standard"]
[TimeControl "180+2"]
[ECO "A56"]
[Termination "Unknown"]
[Annotator "lichess.org"]

1. d4 { [%eval 0.17] [%clk 0:03:00] } 1... Nf6 { [%eval 0.19] [%clk 0:02:59] } 2. c4 { [%eval 0.18] [%clk 0:03:01] } 2... c5 { [%eval 0.56] [%clk 0:02:58] } { A56 Benoni Defense } 3. e3 { [%eval 0.08] [%clk 0:03:02] } 3... g6 { [%eval 0.25] [%clk 0:02:50] } 4. Nc3 { [%eval 0.21] [%clk 0:03:01] } 4... Bg7 { [%eval 0.2] [%clk 0:02:51] } 5. Nf3 { [%eval 0.0] [%clk 0:03:01] } 5... O-O { [%eval 0.36] [%clk 0:02:52] } 6. Be2 { [%eval -0.09] [%clk 0:03:01] } 6... b6?! { (-0.09 → 0.53) Inaccuracy. cxd4 was best. } { [%eval 0.53] [%clk 0:02:43] } (6... cxd4 7. Qxd4 d5 8. Nxd5 Nc6 9. Qd1 Be6 10. Nxf6+ Bxf6 11. O-O) 7. d5 { [%eval 0.48] [%clk 0:03:00] } 7... d6 { [%eval 0.57] [%clk 0:02:39] } 8. e4 { [%eval 0.58] [%clk 0:02:59] } 8... e6 { [%eval 0.62] [%clk 0:02:36] } 9. dxe6?! { (0.62 → 0.01) Inaccuracy. O-O was best. } { [%eval 0.01] [%clk 0:02:57] } (9. O-O exd5 10. cxd5 Re8 11. Nd2 Ba6 12. a4 Bxe2 13. Qxe2 Qe7 14. Re1 Nbd7) 9... fxe6 { [%eval 0.0] [%clk 0:02:30] } 10. Bg5 { [%eval 0.01] [%clk 0:02:58] } 10... h6 { [%eval 0.18] [%clk 0:02:23] } 11. Bh4 { [%eval -0.28] [%clk 0:02:57] } 11... Qe7?? { (-0.28 → 1.60) Blunder. Nc6 was best. } { [%eval 1.6] [%clk 0:02:15] } (11... Nc6 12. O-O Bb7 13. Bg3 e5 14. Nd5 Kh7 15. Bh4 Qd7 16. Nd2 Nd4 17. Bxf6) 12. e5 { [%eval 1.61] [%clk 0:02:52] } 12... dxe5 { [%eval 1.65] [%clk 0:02:09] } 13. Nxe5 { [%eval 1.63] [%clk 0:02:53] } 13... Rd8 { [%eval 1.36] [%clk 0:02:07] } 14. Qc2 { [%eval 1.6] [%clk 0:02:44] } 14... Bb7? { (1.60 → 2.95) Mistake. g5 was best. } { [%eval 2.95] [%clk 0:01:54] } (14... g5 15. Bg3) 15. Qxg6 { [%eval 3.0] [%clk 0:02:34] } 15... Nbd7 { [%eval 3.17] [%clk 0:01:41] } 16. Ng4 { [%eval 2.7] [%clk 0:02:26] } 16... Qf7?? { (2.70 → 9.69) Blunder. Qe8 was best. } { [%eval 9.69] [%clk 0:01:34] } (16... Qe8 17. Nxh6+ Kf8 18. Qxe8+ Rxe8 19. Bg5 Nh7 20. Be3 Ne5 21. O-O Ke7 22. Rfe1) 17. Nxh6+ { [%eval 9.62] [%clk 0:02:25] } { White wins. } 1-0'''

    print("=== Debugging User's Game ===")
    processor = PGNProcessor()
    game_data = processor.parse_pgn(user_pgn)

    if not game_data:
        print("Failed to parse PGN!")
        return

    print("=== All Moves with NAGs ===")
    for i, move in enumerate(game_data.main_line):
        nag_str = f" {move.nags}" if move.nags else ""
        comment_str = f" ({move.comment_text})" if move.comments else ""
        print(f"{i+1:2d}. {move.san}{nag_str} (Move {move.move_number}){comment_str}")

    print("\n=== Moves with NAG Annotations ===")
    nag_moves = []
    for i, move in enumerate(game_data.main_line):
        if move.nags:
            nag_moves.append((i, move))

    print(f"Found {len(nag_moves)} moves with NAGs:")
    for i, move in nag_moves:
        print(f"  Move {move.move_number}: {move.san} {move.nags}")

    print("\n=== Expected Missing Moves ===")
    expected_missing = ["b6?!", "dxe6?!", "Qe7??", "Bb7?", "Qf7??"]
    for expected in expected_missing:
        move_base = expected.replace("?", "").replace("!", "")
        found = any(move.san == move_base for move in game_data.main_line)
        print(f"  {expected}: {'✅ Found' if found else '❌ Missing'}")

    print("\n=== Formatted Game ===")
    formatted = processor.format_moves_with_annotations(game_data.main_line)
    print(formatted)

if __name__ == "__main__":
    debug_user_game()