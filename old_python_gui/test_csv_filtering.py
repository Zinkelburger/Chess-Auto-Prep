#!/usr/bin/env python3
"""
Test that the CSV maker properly filters out inaccuracies.
"""

import sys
sys.path.append('/var/home/bigman/Documents/CodingProjects/Chess-Auto-Prep')

from scripts.tactics_analyzer import TacticsAnalyzer

def test_csv_filtering():
    """Test that inaccuracies are excluded from CSV creation."""

    analyzer = TacticsAnalyzer("TestUser")

    print("=== Testing CSV Mistake Type Extraction ===")

    test_cases = [
        ("Blunder. Nc6 was best.", "??"),
        ("Mistake. O-O was best.", "?"),
        ("Inaccuracy. cxd4 was best.", None),  # Should return None now
        ("Good move! This is strong.", None),
        ("", None),
    ]

    print("\n=== Test Results ===")
    for comment, expected in test_cases:
        result = analyzer._extract_mistake_type(comment)
        status = "✅" if result == expected else "❌"
        print(f"{status} Comment: '{comment}'")
        print(f"   Expected: {expected}")
        print(f"   Got:      {result}")
        print()

    print("=== Summary ===")
    passed = sum(1 for comment, exp in test_cases if analyzer._extract_mistake_type(comment) == exp)
    total = len(test_cases)
    print(f"Passed: {passed}/{total} tests")

    if passed == total:
        print("✅ SUCCESS: Inaccuracies will NOT be saved to CSV!")
    else:
        print("❌ FAILED: Some tests didn't pass")

if __name__ == "__main__":
    test_csv_filtering()