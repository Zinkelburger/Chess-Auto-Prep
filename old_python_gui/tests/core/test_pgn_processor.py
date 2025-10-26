"""
Comprehensive tests for the PGN processor module.
Tests all critical functionality with edge cases and error conditions.
"""
import pytest
from unittest.mock import Mock, patch
import chess
import chess.pgn
import io

from core.pgn_processor import (
    PGNProcessor, GameData, MoveData, VariationData, NAG_MAP
)


class TestPGNProcessor:
    """Test suite for PGNProcessor class."""

    def test_init(self):
        """Test PGNProcessor initialization."""
        processor = PGNProcessor()
        assert processor.current_board is None

    @pytest.mark.pgn
    def test_parse_simple_pgn(self, pgn_processor: PGNProcessor):
        """Test parsing a simple PGN without annotations."""
        simple_pgn = '''[Event "Simple Game"]
[White "Player1"]
[Black "Player2"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 1-0'''

        game_data = pgn_processor.parse_pgn(simple_pgn)

        assert game_data is not None
        assert game_data.headers['Event'] == 'Simple Game'
        assert game_data.headers['White'] == 'Player1'
        assert game_data.headers['Result'] == '1-0'
        assert len(game_data.main_line) == 5  # 5 moves total

    @pytest.mark.pgn
    def test_parse_pgn_with_nags(self, pgn_processor: PGNProcessor):
        """Test parsing PGN with NAG annotations."""
        pgn_with_nags = '''[Event "NAG Test"]
[White "Player1"]
[Black "Player2"]
[Result "0-1"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6?! 4. Ba4 Nf6?? 0-1'''

        game_data = pgn_processor.parse_pgn(pgn_with_nags)

        assert game_data is not None

        # Find moves with NAGs
        nag_moves = [move for move in game_data.main_line if move.nags]
        assert len(nag_moves) == 2

        # Check specific NAG symbols
        a6_move = next(move for move in game_data.main_line if move.san == 'a6')
        assert '?!' in a6_move.nags

        nf6_move = next(move for move in game_data.main_line if move.san == 'Nf6')
        assert '??' in nf6_move.nags

    @pytest.mark.pgn
    def test_parse_pgn_with_comments(self, pgn_processor: PGNProcessor):
        """Test parsing PGN with comments (filtered)."""
        pgn_with_comments = '''[Event "Comment Test"]
[White "Player1"]
[Black "Player2"]
[Result "1-0"]

1. e4 { A solid opening } e5 2. Nf3 { [%eval 0.17] [%clk 0:03:00] } Nc6
3. Bb5 { Inaccuracy. Bc4 was best. } a6 { The Spanish opening! } 1-0'''

        game_data = pgn_processor.parse_pgn(pgn_with_comments)

        assert game_data is not None

        # Check that meaningful comments are kept
        e4_move = next(move for move in game_data.main_line if move.san == 'e4')
        assert 'A solid opening' in e4_move.comment_text

        # Check that eval/clock comments are filtered out
        nf3_move = next(move for move in game_data.main_line if move.san == 'Nf3')
        assert nf3_move.comments == []  # Should be filtered out

        # Check that inaccuracy comments are filtered out
        bb5_move = next(move for move in game_data.main_line if move.san == 'Bb5')
        assert bb5_move.comments == []  # Should be filtered out

        # Check that meaningful comments are kept
        a6_move = next(move for move in game_data.main_line if move.san == 'a6')
        assert 'The Spanish opening!' in a6_move.comment_text

    @pytest.mark.pgn
    def test_parse_pgn_with_variations(self, pgn_processor: PGNProcessor):
        """Test parsing PGN with variations."""
        pgn_with_variations = '''[Event "Variation Test"]
[White "Player1"]
[Black "Player2"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 (3... f5 4. exf5 e4 5. Nh4) 4. Ba4 1-0'''

        game_data = pgn_processor.parse_pgn(pgn_with_variations)

        assert game_data is not None

        # Find move with variations
        a6_move = next(move for move in game_data.main_line if move.san == 'a6')
        assert len(a6_move.variations) > 0

        # Check variation content
        variation = a6_move.variations[0]
        assert len(variation.moves) > 0
        # The variation is (3... f5 4. exf5 e4 5. Nh4)
        # So the moves in the variation should be exf5, e4, Nh4
        move_sans = [move.san for move in variation.moves]
        assert 'exf5' in move_sans  # White's response to f5

    @pytest.mark.pgn
    def test_extract_tactical_positions(self, pgn_processor: PGNProcessor):
        """Test extraction of tactical positions."""
        tactical_pgn = '''[Event "Tactical Test"]
[White "Player1"]
[Black "Player2"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 f5?? 4. exf5! e4 5. Qh5+ g6 6. fxg6 1-0'''

        game_data = pgn_processor.parse_pgn(tactical_pgn)
        tactical_positions = pgn_processor.extract_tactical_positions(game_data)

        assert len(tactical_positions) == 1  # Only f5?? should be extracted (no inaccuracies)

        position = tactical_positions[0]
        assert position['move_played'] == 'f5'
        assert '??' in position['annotations']
        assert position['is_white_to_move'] == False

    @pytest.mark.pgn
    def test_find_moves_with_annotation(self, pgn_processor: PGNProcessor):
        """Test finding moves with specific annotations."""
        game_data = pgn_processor.parse_pgn('''[Event "Test"]
[White "P1"][Black "P2"][Result "1-0"]
1. e4 e5? 2. Nf3 Nc6?? 3. Bb5 a6?! 1-0''')

        # Find blunders
        blunders = pgn_processor.find_moves_with_annotation(game_data, '??')
        assert len(blunders) == 1
        assert blunders[0][1].san == 'Nc6'

        # Find mistakes
        mistakes = pgn_processor.find_moves_with_annotation(game_data, '?')
        assert len(mistakes) == 1
        assert mistakes[0][1].san == 'e5'

        # Find inaccuracies
        inaccuracies = pgn_processor.find_moves_with_annotation(game_data, '?!')
        assert len(inaccuracies) == 1
        assert inaccuracies[0][1].san == 'a6'

    @pytest.mark.pgn
    def test_get_position_at_move(self, pgn_processor: PGNProcessor):
        """Test getting board position at specific move."""
        game_data = pgn_processor.parse_pgn('''[Event "Test"]
[White "P1"][Black "P2"][Result "1-0"]
1. e4 e5 2. Nf3 1-0''')

        # Position after e4
        board = pgn_processor.get_position_at_move(game_data, 0)
        assert board.piece_at(chess.E4).piece_type == chess.PAWN
        assert board.turn == chess.BLACK

        # Position after e5
        board = pgn_processor.get_position_at_move(game_data, 1)
        assert board.piece_at(chess.E5).piece_type == chess.PAWN
        assert board.turn == chess.WHITE

    @pytest.mark.pgn
    def test_format_moves_with_annotations(self, pgn_processor: PGNProcessor):
        """Test formatting moves with annotations for display."""
        game_data = pgn_processor.parse_pgn('''[Event "Test"]
[White "P1"][Black "P2"][Result "1-0"]
1. e4 {Good!} e5? 2. Nf3! 1-0''')

        formatted = pgn_processor.format_moves_with_annotations(game_data.main_line)

        assert '1. e4' in formatted
        assert 'e5?' in formatted
        assert '2. Nf3!' in formatted
        assert '(Good!)' in formatted

    def test_parse_invalid_pgn(self, pgn_processor: PGNProcessor):
        """Test parsing invalid PGN returns None."""
        invalid_pgn = "This is not a valid PGN"
        result = pgn_processor.parse_pgn(invalid_pgn)
        assert result is None

    def test_parse_empty_pgn(self, pgn_processor: PGNProcessor):
        """Test parsing empty PGN returns None."""
        result = pgn_processor.parse_pgn("")
        assert result is None

    def test_parse_pgn_file_not_exists(self, pgn_processor: PGNProcessor):
        """Test parsing non-existent PGN file."""
        games = pgn_processor.parse_pgn_file("/nonexistent/file.pgn")
        assert games == []

    @pytest.mark.pgn
    def test_filter_comment_edge_cases(self, pgn_processor: PGNProcessor):
        """Test comment filtering edge cases."""
        # Test various comment patterns
        test_cases = [
            ("", ""),
            ("   ", ""),
            ("[%eval 0.17]", ""),
            ("Good move!", "Good move!"),
            ("(-0.09 → 0.53) Inaccuracy. cxd4 was best.", ""),
            ("A56 Benoni Defense [%eval 0.56]", "A56 Benoni Defense"),
        ]

        for input_comment, expected in test_cases:
            result = pgn_processor._filter_comment(input_comment)
            assert result == expected, f"Failed for input: '{input_comment}'"

    @pytest.mark.pgn
    def test_nag_mapping_completeness(self):
        """Test that NAG mapping covers common annotations."""
        essential_nags = {1: '!', 2: '?', 3: '!!', 4: '??', 5: '!?', 6: '?!'}

        for nag_code, symbol in essential_nags.items():
            assert nag_code in NAG_MAP
            assert NAG_MAP[nag_code] == symbol

    @pytest.mark.pgn
    def test_move_data_properties(self):
        """Test MoveData properties and methods."""
        move = MoveData(
            san="Nf3",
            uci="g1f3",
            nags=["!", "?"],
            comments=["Good move", "But risky"],
            variations=[],
            move_number=2,
            is_white_move=True,
            fen_before="start_fen",
            fen_after="end_fen"
        )

        assert move.display_text == "Nf3!?"
        assert move.comment_text == "Good move But risky"

    @pytest.mark.pgn
    def test_variation_data_structure(self):
        """Test VariationData structure."""
        variation = VariationData(
            moves=[],
            comment="Test variation"
        )

        assert variation.moves == []
        assert variation.comment == "Test variation"

    @pytest.mark.slow
    @pytest.mark.pgn
    def test_large_pgn_performance(self, pgn_processor: PGNProcessor, benchmark_pgn: str):
        """Test performance with large PGN files."""
        # This would be used with pytest-benchmark if available
        game_data = pgn_processor.parse_pgn(benchmark_pgn)
        assert game_data is not None
        assert len(game_data.main_line) > 50

    @pytest.mark.unit
    def test_chess_integration(self):
        """Test integration with python-chess library."""
        processor = PGNProcessor()

        # Test that we can create valid chess positions
        board = chess.Board()
        assert board.is_valid()

        # Test move parsing
        move = chess.Move.from_uci("e2e4")
        assert move.uci() == "e2e4"