#!/usr/bin/env python3
"""
Test script to validate the highlighting color fix.
"""
import re

def test_highlighting_color_change():
    """Test that the highlighting color has been changed from green to blue."""

    # Read the chess board widget file
    with open('ui/chess_board.py', 'r') as f:
        content = f.read()

    # Check that the highlighting color is now blue (RGB: 0, 100, 255)
    # and not green (RGB: 0, 255, 0)

    # Look for the highlight_color definition
    highlight_color_match = re.search(r'highlight_color = QColor\((\d+), (\d+), (\d+), (\d+)\)', content)

    if highlight_color_match:
        r, g, b, a = map(int, highlight_color_match.groups())
        print(f"Found highlight color: RGB({r}, {g}, {b}, {a})")

        # Check that it's blue-ish (more blue than green/red)
        if b > g and b > r:
            print("✅ Highlighting color is now blue-based!")
            return True
        else:
            print("❌ Highlighting color is not blue-based")
            return False
    else:
        print("❌ Could not find highlight_color definition")
        return False

def test_interactivity_fix():
    """Test that the interactivity fix has been applied."""

    # Read the tactics review widget file
    with open('ui/tactics_review_widget.py', 'r') as f:
        content = f.read()

    # Check that set_interactive(True) is called after set_board
    if 'self.chess_board.set_interactive(True)' in content:
        print("✅ Interactivity fix has been applied!")
        return True
    else:
        print("❌ Interactivity fix not found")
        return False

if __name__ == "__main__":
    print("Testing highlighting and interactivity fixes...")
    print("=" * 50)

    color_test = test_highlighting_color_change()
    interactivity_test = test_interactivity_fix()

    print("=" * 50)
    if color_test and interactivity_test:
        print("🎉 All fixes have been successfully applied!")
    else:
        print("⚠️  Some fixes may not have been applied correctly.")