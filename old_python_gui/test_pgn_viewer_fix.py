#!/usr/bin/env python3
"""
Test the fixed PGN viewer to ensure NAG moves are displayed.
"""

import chess.pgn
import io
from widgets.pgn_viewer import PGNViewerWidget

def test_nag_display():
    """Test that the PGN viewer now shows moves with NAGs."""

    # Simplified version of user's game with key NAG moves
    test_pgn = '''[Event "NAG Test"]
[White "Player1"]
[Black "Player2"]
[Result "1-0"]

1. d4 Nf6 2. c4 c5 3. e3 g6 4. Nc3 Bg7 5. Nf3 O-O 6. Be2 b6?! (6... cxd4 7. Qxd4) 7. d5 d6 8. e4 e6 9. dxe6?! fxe6 10. Bg5 h6 11. Bh4 Qe7?? 12. e5 dxe5 13. Nxe5 Bb7? 14. Qxg6 Qf7?? 15. Nxh6+ 1-0'''

    print("=== Testing Fixed PGN Viewer ===")

    # Parse the PGN
    game = chess.pgn.read_game(io.StringIO(test_pgn))
    if not game:
        print("❌ Failed to parse test PGN")
        return

    print("✅ Game parsed successfully")

    # Create PGN viewer widget
    viewer = PGNViewerWidget()

    # Test the _format_node method directly
    print("\n=== Testing _format_node method ===")
    formatted_html = viewer._format_node(game)

    # Check for expected NAG moves
    expected_nags = ["b6?!", "dxe6?!", "Qe7??", "Bb7?", "Qf7??"]

    print("\n=== Checking for NAG moves ===")
    for expected in expected_nags:
        if expected in formatted_html:
            print(f"✅ Found: {expected}")
        else:
            print(f"❌ Missing: {expected}")

    print("\n=== Formatted HTML Output (first 500 chars) ===")
    print(formatted_html[:500] + "...")

    # Count total moves in output
    move_count = formatted_html.count('<a href="#')
    print(f"\n=== Total moves found in output: {move_count} ===")

    # Test full widget loading
    print("\n=== Testing full widget loading ===")
    viewer.load_pgn(test_pgn)

    print("✅ PGN loaded into widget successfully")

if __name__ == "__main__":
    test_nag_display()