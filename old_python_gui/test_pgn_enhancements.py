#!/usr/bin/env python3
"""
Test script for the enhanced PGN processor.
Tests the key functionality: NAG mapping, comment extraction, and variation handling.
"""

from core.pgn_processor import PGNProcessor

def test_basic_annotations():
    """Test basic NAG annotation parsing."""
    pgn_with_nags = '''[Event "Test Game"]
[Site "Test"]
[Date "2023.01.01"]
[Round "1"]
[White "Player A"]
[Black "Player B"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6?! 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5?? 7. Bb3 1-0'''

    processor = PGNProcessor()
    game_data = processor.parse_pgn(pgn_with_nags)

    print("=== Basic Annotations Test ===")
    if game_data:
        # Find moves with annotations
        moves_with_annotations = []
        for i, move in enumerate(game_data.main_line):
            if move.nags:
                moves_with_annotations.append((i, move))

        print(f"Found {len(moves_with_annotations)} moves with annotations:")
        for i, move in moves_with_annotations:
            print(f"  Move {move.move_number}: {move.san} {move.nags}")

        # Test formatting
        formatted = processor.format_moves_with_annotations(game_data.main_line)
        print(f"\nFormatted game: {formatted}")
    else:
        print("Failed to parse PGN")

def test_comments():
    """Test comment extraction."""
    pgn_with_comments = '''[Event "Test Game"]
[Site "Test"]
[Date "2023.01.01"]
[Round "1"]
[White "Player A"]
[Black "Player B"]
[Result "1-0"]

1. e4 {A solid opening} e5 2. Nf3 {Developing with tempo} Nc6 3. Bb5 {The Ruy Lopez} a6 {Attacking the bishop} 4. Ba4 1-0'''

    processor = PGNProcessor()
    game_data = processor.parse_pgn(pgn_with_comments)

    print("\n=== Comments Test ===")
    if game_data:
        moves_with_comments = []
        for i, move in enumerate(game_data.main_line):
            if move.comments:
                moves_with_comments.append((i, move))

        print(f"Found {len(moves_with_comments)} moves with comments:")
        for i, move in moves_with_comments:
            print(f"  Move {move.move_number}: {move.san} - {move.comment_text}")
    else:
        print("Failed to parse PGN")

def test_variations():
    """Test variation parsing."""
    pgn_with_variations = '''[Event "Test Game"]
[Site "Test"]
[Date "2023.01.01"]
[Round "1"]
[White "Player A"]
[Black "Player B"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 (3... f5 4. exf5 e4 5. Nh4) 4. Ba4 Nf6 5. O-O Be7 1-0'''

    processor = PGNProcessor()
    game_data = processor.parse_pgn(pgn_with_variations)

    print("\n=== Variations Test ===")
    if game_data:
        moves_with_variations = []
        for i, move in enumerate(game_data.main_line):
            if move.variations:
                moves_with_variations.append((i, move))

        print(f"Found {len(moves_with_variations)} moves with variations:")
        for i, move in moves_with_variations:
            print(f"  Move {move.move_number}: {move.san}")
            for j, variation in enumerate(move.variations):
                var_text = processor.format_moves_with_annotations(variation.moves)
                print(f"    Variation {j+1}: {var_text}")

        # Test full formatting with variations
        formatted = processor.format_moves_with_annotations(game_data.main_line)
        print(f"\nFormatted game with variations: {formatted}")
    else:
        print("Failed to parse PGN")

def test_tactical_extraction():
    """Test extraction of tactical positions."""
    pgn_tactical = '''[Event "Tactical Game"]
[Site "Test"]
[Date "2023.01.01"]
[Round "1"]
[White "Player A"]
[Black "Player B"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 f5?? 4. exf5! e4 5. Qh5+ g6 6. fxg6 hxg6?? 7. Qxg6# 1-0'''

    processor = PGNProcessor()
    game_data = processor.parse_pgn(pgn_tactical)

    print("\n=== Tactical Positions Test ===")
    if game_data:
        tactical_positions = processor.extract_tactical_positions(game_data)
        print(f"Found {len(tactical_positions)} tactical positions:")

        for pos in tactical_positions:
            print(f"  Move {pos['move_number']}: {pos['move_played']} {pos['annotations']}")
            print(f"    FEN: {pos['fen']}")
            if pos['comments']:
                print(f"    Comments: {pos['comments']}")
            print()
    else:
        print("Failed to parse PGN")

def test_find_annotations():
    """Test finding specific annotations."""
    pgn_mixed = '''[Event "Mixed Game"]
[Site "Test"]
[Date "2023.01.01"]
[Round "1"]
[White "Player A"]
[Black "Player B"]
[Result "1-0"]

1. e4 e5 2. Nf3! Nc6 3. Bb5 a6? 4. Ba4 Nf6 5. O-O?! Be7 6. Re1 b5?? 7. Bb3!! 1-0'''

    processor = PGNProcessor()
    game_data = processor.parse_pgn(pgn_mixed)

    print("\n=== Find Annotations Test ===")
    if game_data:
        # Find blunders
        blunders = processor.find_moves_with_annotation(game_data, "??")
        print(f"Blunders (??): {len(blunders)}")
        for i, move in blunders:
            print(f"  Move {move.move_number}: {move.san}")

        # Find good moves
        good_moves = processor.find_moves_with_annotation(game_data, "!")
        print(f"Good moves (!): {len(good_moves)}")
        for i, move in good_moves:
            print(f"  Move {move.move_number}: {move.san}")

        # Find brilliant moves
        brilliant = processor.find_moves_with_annotation(game_data, "!!")
        print(f"Brilliant moves (!!): {len(brilliant)}")
        for i, move in brilliant:
            print(f"  Move {move.move_number}: {move.san}")
    else:
        print("Failed to parse PGN")

if __name__ == "__main__":
    print("Testing Enhanced PGN Processor")
    print("=" * 50)

    test_basic_annotations()
    test_comments()
    test_variations()
    test_tactical_extraction()
    test_find_annotations()

    print("\n" + "=" * 50)
    print("All tests completed!")