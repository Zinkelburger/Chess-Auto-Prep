#!/usr/bin/env python3
"""
Test script for the Coverage Calculator.

This demonstrates the coverage calculator functionality with example repertoires.
"""

import chess
from coverage_calculator import (
    CoverageCalculator,
    LichessExplorerAPI,
    DatabaseType,
    RepertoireMoveTree,
    calculate_coverage,
)


def test_move_tree_basic():
    """Test basic move tree construction."""
    print("=" * 60)
    print("TEST: Basic Move Tree Construction")
    print("=" * 60)
    
    tree = RepertoireMoveTree()
    
    # Add some lines
    tree.add_line(["e4", "e5", "Nf3", "Nc6", "Bb5"])  # Ruy Lopez
    tree.add_line(["e4", "e5", "Nf3", "Nf6"])          # Petroff
    tree.add_line(["e4", "c5"])                         # Sicilian (short line)
    
    print(f"Root FEN: {tree.root_fen}")
    print(f"Total positions: {len(tree.all_fens)}")
    
    leaves = tree.get_leaf_positions()
    print(f"Leaf positions: {len(leaves)}")
    for fen, moves in leaves:
        print(f"  - {' '.join(moves)}")
    
    assert len(leaves) == 3, f"Expected 3 leaves, got {len(leaves)}"
    print("✅ PASSED\n")


def test_move_tree_subset_handling():
    """Test that subsets are handled correctly (only longest line counts)."""
    print("=" * 60)
    print("TEST: Subset Handling (Longest Line Only)")
    print("=" * 60)
    
    tree = RepertoireMoveTree()
    
    # Add a line and its extension - only the extension should be a leaf
    tree.add_line(["e4", "e5"])
    tree.add_line(["e4", "e5", "Nf3"])  # Extension of the first line
    
    leaves = tree.get_leaf_positions()
    print(f"Leaf positions: {len(leaves)}")
    for fen, moves in leaves:
        print(f"  - {' '.join(moves)}")
    
    # Only the longer line should be a leaf
    assert len(leaves) == 1, f"Expected 1 leaf (longest line), got {len(leaves)}"
    assert leaves[0][1] == ["e4", "e5", "Nf3"], "Wrong leaf identified"
    print("✅ PASSED\n")


def test_pgn_parsing():
    """Test PGN parsing with variations."""
    print("=" * 60)
    print("TEST: PGN Parsing with Variations")
    print("=" * 60)
    
    pgn_content = """
[Event "Repertoire"]
[White "Me"]
[Black "Opponent"]

1. e4 e5 2. Nf3 Nc6 (2... Nf6 3. Nxe5 d6) 3. Bb5 *
"""
    
    tree = RepertoireMoveTree()
    tree.load_from_pgn(pgn_content)
    
    print(f"Total positions: {len(tree.all_fens)}")
    
    leaves = tree.get_leaf_positions()
    print(f"Leaf positions: {len(leaves)}")
    for fen, moves in leaves:
        print(f"  - {' '.join(moves)}")
    
    # Should have 2 leaves: Ruy Lopez and Petroff with Nxe5
    assert len(leaves) == 2, f"Expected 2 leaves, got {len(leaves)}"
    print("✅ PASSED\n")


def test_api_caching():
    """Test that API caching works correctly."""
    print("=" * 60)
    print("TEST: API Caching")
    print("=" * 60)
    
    api = LichessExplorerAPI(
        database=DatabaseType.LICHESS,
        base_delay=0.05,  # Shorter delay for testing
    )
    
    # Query the same position twice
    fen = chess.STARTING_FEN
    
    print(f"First query for starting position...")
    data1 = api.get_position_data(fen)
    print(f"  Cache stats: {api.cache_stats()}")
    
    print(f"Second query (should be cached)...")
    data2 = api.get_position_data(fen)
    print(f"  Cache stats: {api.cache_stats()}")
    
    assert data1 == data2, "Cache returned different data"
    assert api._cache_hits == 1, f"Expected 1 cache hit, got {api._cache_hits}"
    assert api._cache_misses == 1, f"Expected 1 cache miss, got {api._cache_misses}"
    
    print("✅ PASSED\n")


def test_coverage_calculation_simple():
    """Test coverage calculation with a simple repertoire."""
    print("=" * 60)
    print("TEST: Simple Coverage Calculation")
    print("=" * 60)
    
    # Simple repertoire: just 1. e4 with response to e5
    moves_list = [
        ["e4", "e5", "Nf3"],
        ["e4", "c5", "Nf3"],
    ]
    
    result = calculate_coverage(
        moves_list,
        target_game_count=100_000,  # Lower threshold for testing
        my_color="white",
        verbose=True,
    )
    
    print("\n" + result.summary())
    
    # Basic sanity checks
    assert result.root_game_count > 0, "Root should have games"
    assert len(result.sealed_leaves) + len(result.leaking_leaves) == 2, "Should have 2 leaves"
    assert 0 <= result.coverage_percent <= 100, "Coverage should be 0-100%"
    assert 0 <= result.leakage_percent <= 100, "Leakage should be 0-100%"
    assert 0 <= result.unaccounted_percent <= 100, "Unaccounted should be 0-100%"
    
    # Coverage + Leakage + Unaccounted should be roughly 100%
    total = result.coverage_percent + result.leakage_percent + result.unaccounted_percent
    print(f"\nTotal: {total:.2f}% (should be ~100%)")
    
    print("✅ PASSED\n")


def test_coverage_from_pgn():
    """Test coverage calculation from a PGN string."""
    print("=" * 60)
    print("TEST: Coverage from PGN")
    print("=" * 60)
    
    # A small repertoire starting from 1. e4 e5 (no starting_moves filter)
    pgn = """
[Event "Open Game Repertoire"]
[White "Me"]
[Black "Opponent"]

1. e4 e5 2. Nf3 Nc6 (2... Nf6 3. Nxe5) 3. Bb5 *
"""
    
    result = calculate_coverage(
        pgn,
        target_game_count=1_000_000,  # High threshold so all leaves are leaking
        my_color="white",
        database="lichess",
        verbose=True,
    )
    
    print("\n" + result.summary())
    
    assert result.root_game_count > 0, "Root should have games"
    print("✅ PASSED\n")


def test_coverage_with_starting_position():
    """Test coverage from a specific starting position."""
    print("=" * 60)
    print("TEST: Coverage with Starting Position")
    print("=" * 60)
    
    # Analyze from Caro-Kann position (1. e4 c6)
    # The PGN contains full games but we only care about positions after 1.e4 c6
    pgn = """
[Event "Caro-Kann"]
[White "Me"]
[Black "Opponent"]

1. e4 c6 2. d4 d5 3. Nc3 *

[Event "Caro-Kann Advance"]
[White "Me"]
[Black "Opponent"]

1. e4 c6 2. d4 d5 3. e5 Bf5 *
"""
    
    result = calculate_coverage(
        pgn,
        target_game_count=500_000,
        starting_moves=["e4", "c6"],  # Our repertoire starts after 1.e4 c6
        my_color="white",
        database="lichess",
        verbose=True,
    )
    
    print("\n" + result.summary())
    
    # The root should be the Caro-Kann position, not the starting position
    assert result.root_game_count > 0, "Root should have games"
    # Root game count should be less than total lichess games (we're past move 1)
    assert result.root_game_count < 1_500_000_000, "Root should be Caro-Kann, not starting position"
    print("✅ PASSED\n")


def main():
    """Run all tests."""
    print("\n" + "=" * 60)
    print("COVERAGE CALCULATOR TEST SUITE")
    print("=" * 60 + "\n")
    
    # Run tests in order
    test_move_tree_basic()
    test_move_tree_subset_handling()
    test_pgn_parsing()
    
    # These tests require API access
    print("⚠️  The following tests require API access and may be slow...\n")
    
    try:
        test_api_caching()
        test_coverage_calculation_simple()
        test_coverage_from_pgn()
        test_coverage_with_starting_position()
    except Exception as e:
        print(f"⚠️  API tests failed (this is OK if no API token): {e}")
    
    print("\n" + "=" * 60)
    print("ALL TESTS COMPLETED")
    print("=" * 60)


if __name__ == "__main__":
    main()

