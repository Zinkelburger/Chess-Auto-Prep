#!/usr/bin/env python3
"""
Debug the source of the PGN display issue by testing both parsers.
"""

import chess
import chess.pgn
import io

def test_standard_parser():
    """Test the standard chess.pgn parser on user's game."""

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

    print("=== Testing Standard chess.pgn Parser ===")

    try:
        game = chess.pgn.read_game(io.StringIO(user_pgn))
        if not game:
            print("❌ Failed to parse game")
            return

        print("✅ Game parsed successfully")

        # Test basic traversal
        print("\n=== Basic Traversal (like current PGN viewer) ===")
        board = game.board()
        node = game
        move_count = 0

        while node.variations and move_count < 40:  # Safety limit
            child = node.variations[0]
            move = child.move
            san = board.san(move)

            # Check NAGs
            nag_symbols = []
            for nag in child.nags:
                if nag == 2:
                    nag_symbols.append("?")
                elif nag == 4:
                    nag_symbols.append("??")
                elif nag == 5:
                    nag_symbols.append("?!")
                elif nag == 1:
                    nag_symbols.append("!")
                elif nag == 3:
                    nag_symbols.append("!!")

            nag_str = "".join(nag_symbols)

            print(f"{move_count+1:2d}. {san}{nag_str} (NAGs: {list(child.nags)}) ({'White' if board.turn else 'Black'})")

            if child.comment:
                print(f"     Comment: {child.comment[:50]}...")

            board.push(move)
            node = child
            move_count += 1

        print(f"\n✅ Successfully processed {move_count} moves")

        # Now test what the current PGN viewer would show
        print("\n=== Simulating Current PGN Viewer Logic ===")

        def simulate_pgn_viewer_format(node, move_number=1, depth=0):
            """Simulate the current PGN viewer's _format_node logic."""
            if depth > 5:  # Prevent infinite recursion
                return ""

            html = ""
            board = node.board()

            for child in node.variations:
                move = child.move
                san = board.san(move)

                # Add NAG symbols
                nag_symbols = []
                for nag in child.nags:
                    if nag == 2:
                        nag_symbols.append("?")
                    elif nag == 4:
                        nag_symbols.append("??")
                    elif nag == 5:
                        nag_symbols.append("?!")

                san += "".join(nag_symbols)

                # Show move number for white's moves
                if board.turn == chess.WHITE:
                    html += f"{move_number}. "

                html += f"{san} "

                # Add comment if exists
                if child.comment:
                    html += f"({child.comment[:20]}...) "

                # HERE'S THE PROBLEM: This break means only first variation is processed!
                break  # This is the issue!

            return html

        viewer_output = simulate_pgn_viewer_format(game)
        print("Current viewer would show:", viewer_output[:200] + "...")

    except Exception as e:
        print(f"❌ Error: {e}")

if __name__ == "__main__":
    test_standard_parser()