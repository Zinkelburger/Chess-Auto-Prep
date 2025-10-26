#!/usr/bin/env python3
"""
Test the comment filtering functionality.
"""

import re

def filter_comment(comment: str) -> str:
    """Filter out eval and clock comments, keeping only meaningful text."""
    if not comment:
        return ""

    # Remove eval comments like [%eval 0.17] or [%eval -1.25]
    comment = re.sub(r'\[%eval [^\]]+\]', '', comment)

    # Remove clock comments like [%clk 0:03:00]
    comment = re.sub(r'\[%clk [^\]]+\]', '', comment)

    # Remove engine evaluation text like "(0.62 → 0.01)"
    comment = re.sub(r'\([+-]?\d+\.?\d*\s*[→-]\s*[+-]?\d+\.?\d*\)', '', comment)

    # Remove phrases for mistakes and blunders only (keep inaccuracies)
    comment = re.sub(r'(Mistake|Blunder|Good move|Excellent move|Best move)\.[^.]*\.', '', comment)

    # Remove "was best" phrases
    comment = re.sub(r'[A-Za-z0-9+#-]+\s+was best\.?', '', comment)

    # Clean up extra whitespace
    comment = re.sub(r'\s+', ' ', comment).strip()

    # Return empty string if comment is now empty or just punctuation
    if not comment or comment in '.,;!?':
        return ""

    return comment

def test_comment_filtering():
    """Test various comment filtering scenarios."""

    print("=== Testing Comment Filtering ===")

    test_cases = [
        # Eval/clock comments that should be removed
        ("[%eval 0.17] [%clk 0:03:00]", ""),
        ("[%eval -1.25] [%clk 0:02:30]", ""),

        # Engine evaluation text that should be removed/kept
        ("(-0.09 → 0.53) Inaccuracy. cxd4 was best.", "Inaccuracy."),  # Keep inaccuracy, remove eval and "was best"
        ("(0.62 → 0.01) Inaccuracy. O-O was best.", "Inaccuracy."),   # Keep inaccuracy, remove eval and "was best"
        ("(2.70 → 9.69) Blunder. Qe8 was best.", ""),                # Remove blunder entirely

        # Opening names and meaningful comments that should be kept
        ("A56 Benoni Defense", "A56 Benoni Defense"),
        ("This is an interesting position", "This is an interesting position"),
        ("White has good compensation", "White has good compensation"),

        # Mixed comments - keep meaningful parts
        ("[%eval 0.56] [%clk 0:02:58] A56 Benoni Defense", "A56 Benoni Defense"),
        ("(-0.28 → 1.60) Blunder. Nc6 was best. [%eval 1.6] [%clk 0:02:15]", ""),
        ("A tactical shot! [%eval 2.5]", "A tactical shot!"),

        # Complex real examples from the user's game
        ("(-0.09 → 0.53) Inaccuracy. cxd4 was best. [%eval 0.53] [%clk 0:02:43]", "Inaccuracy."),
        ("(0.62 → 0.01) Inaccuracy. O-O was best. [%eval 0.01] [%clk 0:02:57]", "Inaccuracy."),
        ("(-0.28 → 1.60) Blunder. Nc6 was best. [%eval 1.6] [%clk 0:02:15]", ""),
    ]

    print("\n=== Test Results ===")
    for original, expected in test_cases:
        result = filter_comment(original)
        status = "✅" if result == expected else "❌"
        print(f"{status} Input:    '{original}'")
        print(f"   Expected: '{expected}'")
        print(f"   Got:      '{result}'")
        print()

    print("=== Summary ===")
    passed = sum(1 for orig, exp in test_cases if filter_comment(orig) == exp)
    total = len(test_cases)
    print(f"Passed: {passed}/{total} tests")

if __name__ == "__main__":
    test_comment_filtering()