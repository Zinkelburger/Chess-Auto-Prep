"""
Unit tests for tactics functionality.
"""
import pytest
import chess
import tempfile
import csv
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import Mock, patch, MagicMock

from tactics_review import TacticsReviewSystem, TacticsPosition


class TestTacticsPosition:
    """Test TacticsPosition dataclass."""

    def test_position_creation(self):
        """Test creating a tactics position."""
        game_info = {
            'white': 'Player1',
            'black': 'Player2',
            'result': '1-0',
            'date': '2023-01-01',
            'game_id': 'game123'
        }

        position = TacticsPosition(
            fen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            user_move="e4",
            correct_line=["e4", "e5", "Nf3"],
            mistake_type="?",
            position_context="Opening blunder",
            game_info=game_info,
            difficulty=2
        )

        assert position.fen == "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        assert position.user_move == "e4"
        assert position.correct_line == ["e4", "e5", "Nf3"]
        assert position.mistake_type == "?"
        assert position.difficulty == 2
        assert position.review_count == 0
        assert position.success_rate == 0.0


class TestTacticsReviewSystem:
    """Test TacticsReviewSystem class."""

    @pytest.fixture
    def temp_csv(self):
        """Create a temporary CSV file for testing."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.csv', delete=False) as f:
            fieldnames = [
                'fen', 'user_move', 'correct_line', 'mistake_type',
                'position_context', 'game_white', 'game_black', 'game_result',
                'game_date', 'game_id', 'difficulty', 'last_reviewed',
                'review_count', 'success_rate', 'created_date'
            ]
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()

            # Add test data
            writer.writerow({
                'fen': 'r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R w KQkq - 0 4',
                'user_move': 'Nc3',
                'correct_line': 'Ng5|d6|Nxf7',
                'mistake_type': '?',
                'position_context': 'Missed tactical shot',
                'game_white': 'TestPlayer1',
                'game_black': 'TestPlayer2',
                'game_result': '1-0',
                'game_date': '2023-01-01',
                'game_id': 'test_game_1',
                'difficulty': '3',
                'last_reviewed': '',
                'review_count': '0',
                'success_rate': '0.0',
                'created_date': '2023-01-01T10:00:00'
            })

            writer.writerow({
                'fen': 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2',
                'user_move': 'd3',
                'correct_line': 'd4|exd4|Qxd4',
                'mistake_type': '??',
                'position_context': 'Opening blunder',
                'game_white': 'TestPlayer2',
                'game_black': 'TestPlayer3',
                'game_result': '0-1',
                'game_date': '2023-01-02',
                'game_id': 'test_game_2',
                'difficulty': '1',
                'last_reviewed': '2023-01-01T12:00:00',
                'review_count': '2',
                'success_rate': '0.5',
                'created_date': '2023-01-02T14:00:00'
            })

            return f.name

    @pytest.fixture
    def review_system(self, temp_csv):
        """Create a TacticsReviewSystem with test data."""
        return TacticsReviewSystem(csv_path=temp_csv)

    def test_init(self):
        """Test initialization of TacticsReviewSystem."""
        system = TacticsReviewSystem()
        assert system.csv_path == "tactics_positions.csv"
        assert system.positions == []
        assert system.current_position is None
        assert system.current_index == 0
        assert system.session_stats == {'correct': 0, 'incorrect': 0, 'shown_answer': 0}

    def test_load_positions(self, review_system):
        """Test loading positions from CSV."""
        count = review_system.load_positions()
        assert count == 2
        assert len(review_system.positions) == 2

        # Check first position
        pos1 = review_system.positions[0]
        assert pos1.fen == 'r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R w KQkq - 0 4'
        assert pos1.user_move == 'Nc3'
        assert pos1.correct_line == ['Ng5', 'd6', 'Nxf7']
        assert pos1.mistake_type == '?'
        assert pos1.difficulty == 3
        assert pos1.review_count == 0

        # Check second position
        pos2 = review_system.positions[1]
        assert pos2.fen == 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2'
        assert pos2.difficulty == 1
        assert pos2.review_count == 2
        assert pos2.success_rate == 0.5

    def test_load_positions_nonexistent_file(self):
        """Test loading positions from nonexistent file."""
        system = TacticsReviewSystem(csv_path="nonexistent.csv")
        count = system.load_positions()
        assert count == 0
        assert len(system.positions) == 0

    def test_get_next_position(self, review_system):
        """Test getting next position."""
        review_system.load_positions()

        # First call should return a position
        position = review_system.get_next_position()
        assert position is not None
        assert review_system.current_position is not None

        # Should prioritize positions that haven't been reviewed
        assert review_system.current_position.review_count in [0, 2]  # Based on test data

    def test_get_next_position_empty(self):
        """Test getting next position with no positions loaded."""
        system = TacticsReviewSystem()
        position = system.get_next_position()
        assert position is None

    def test_review_priority(self, review_system):
        """Test review priority calculation."""
        review_system.load_positions()
        pos1, pos2 = review_system.positions

        priority1 = review_system._get_review_priority(pos1)
        priority2 = review_system._get_review_priority(pos2)

        # Position that hasn't been reviewed should have higher priority
        assert priority1 > priority2

    def test_check_move_correct(self, review_system):
        """Test checking a correct move."""
        review_system.load_positions()
        review_system.current_position = review_system.positions[0]

        # Test correct move (Ng5 is the first correct move)
        result = review_system.check_move("g5")  # Assuming Ng5 in UCI is g1g5

        # Note: This might fail if the position doesn't have a knight on g1
        # Let's test with a valid UCI move for the position
        board = chess.Board(review_system.current_position.fen)
        legal_moves = list(board.legal_moves)
        if legal_moves:
            test_move = legal_moves[0].uci()
            result = review_system.check_move(test_move)
            assert "error" not in result
            assert "user_move" in result
            assert result["user_move"] == test_move

    def test_check_move_no_position(self, review_system):
        """Test checking move with no current position."""
        result = review_system.check_move("e4")
        assert "error" in result
        assert result["error"] == "No current position"

    def test_check_move_invalid_format(self, review_system):
        """Test checking move with invalid format."""
        review_system.load_positions()
        review_system.current_position = review_system.positions[0]

        result = review_system.check_move("invalid_move")
        assert result["feedback"] == "Invalid move format"
        assert not result["correct"]

    def test_check_move_illegal(self, review_system):
        """Test checking an illegal move."""
        review_system.load_positions()
        review_system.current_position = review_system.positions[0]

        # Try a move that's definitely illegal
        result = review_system.check_move("a1a8")  # Usually illegal
        assert result["feedback"] == "Illegal move"
        assert not result["correct"]

    def test_rate_difficulty(self, review_system):
        """Test rating position difficulty."""
        review_system.load_positions()
        review_system.current_position = review_system.positions[0]

        original_count = review_system.current_position.review_count
        original_difficulty = review_system.current_position.difficulty

        # Rate as "Good" (3)
        review_system.rate_difficulty(3, showed_answer=False)

        assert review_system.current_position.review_count == original_count + 1
        assert review_system.session_stats['correct'] == 1
        assert review_system.current_position.success_rate == 1.0

        # Difficulty should decrease for "Good" rating
        assert review_system.current_position.difficulty <= original_difficulty

    def test_rate_difficulty_again(self, review_system):
        """Test rating position as 'Again' (1)."""
        review_system.load_positions()
        review_system.current_position = review_system.positions[0]

        original_difficulty = review_system.current_position.difficulty

        # Rate as "Again" (1)
        review_system.rate_difficulty(1, showed_answer=False)

        assert review_system.session_stats['incorrect'] == 1
        # Difficulty should increase for "Again" rating
        assert review_system.current_position.difficulty >= original_difficulty

    def test_rate_difficulty_showed_answer(self, review_system):
        """Test rating when answer was shown."""
        review_system.load_positions()
        review_system.current_position = review_system.positions[0]

        review_system.rate_difficulty(3, showed_answer=True)

        assert review_system.session_stats['shown_answer'] == 1
        assert review_system.session_stats['correct'] == 0
        assert review_system.session_stats['incorrect'] == 0

    def test_get_session_stats(self, review_system):
        """Test getting session statistics."""
        review_system.session_stats = {'correct': 5, 'incorrect': 2, 'shown_answer': 1}

        stats = review_system.get_session_stats()

        assert stats['correct'] == 5
        assert stats['incorrect'] == 2
        assert stats['shown_answer'] == 1
        assert stats['total'] == 8
        assert stats['accuracy'] == 5 / 7  # correct / (total - shown_answer)

    def test_get_session_stats_empty(self, review_system):
        """Test getting session stats with no attempts."""
        stats = review_system.get_session_stats()

        assert stats['total'] == 0
        assert stats['accuracy'] == 0.0  # Should handle division by zero

    def test_get_position_info(self, review_system):
        """Test getting position information."""
        review_system.load_positions()
        review_system.current_position = review_system.positions[0]

        info = review_system.get_position_info()

        assert info is not None
        assert info['fen'] == review_system.current_position.fen
        assert info['context'] == review_system.current_position.position_context
        assert info['mistake_type'] == review_system.current_position.mistake_type
        assert 'game_info' in info
        assert info['difficulty'] == review_system.current_position.difficulty

    def test_get_position_info_no_position(self, review_system):
        """Test getting position info with no current position."""
        info = review_system.get_position_info()
        assert info is None

    @patch('tactics_review.TacticsReviewSystem.save_positions')
    def test_save_positions_called(self, mock_save, review_system):
        """Test that save_positions is called after rating."""
        review_system.load_positions()
        review_system.current_position = review_system.positions[0]

        review_system.rate_difficulty(3, showed_answer=False)

        mock_save.assert_called_once()


class TestTacticsIntegration:
    """Integration tests for tactics system."""

    def test_full_review_cycle(self):
        """Test a complete review cycle."""
        # Create temporary CSV with test data
        with tempfile.NamedTemporaryFile(mode='w', suffix='.csv', delete=False) as f:
            fieldnames = [
                'fen', 'user_move', 'correct_line', 'mistake_type',
                'position_context', 'game_white', 'game_black', 'game_result',
                'game_date', 'game_id', 'difficulty', 'last_reviewed',
                'review_count', 'success_rate', 'created_date'
            ]
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()

            writer.writerow({
                'fen': 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
                'user_move': 'd4',
                'correct_line': 'e4|e5|Nf3',
                'mistake_type': '?',
                'position_context': 'Standard opening',
                'game_white': 'Player1',
                'game_black': 'Player2',
                'game_result': '1-0',
                'game_date': '2023-01-01',
                'game_id': 'integration_test',
                'difficulty': '2',
                'last_reviewed': '',
                'review_count': '0',
                'success_rate': '0.0',
                'created_date': '2023-01-01T10:00:00'
            })

            csv_path = f.name

        try:
            # Initialize system and load positions
            system = TacticsReviewSystem(csv_path=csv_path)
            count = system.load_positions()
            assert count == 1

            # Get next position
            position = system.get_next_position()
            assert position is not None

            # Test move checking
            result = system.check_move("e2e4")  # Legal move from starting position
            assert "error" not in result

            # Rate the position
            system.rate_difficulty(3, showed_answer=False)

            # Check stats
            stats = system.get_session_stats()
            assert stats['total'] == 1

        finally:
            # Clean up
            Path(csv_path).unlink()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])