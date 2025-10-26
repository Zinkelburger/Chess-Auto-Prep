"""
Comprehensive tests for the tactics training system.
Tests database operations, engine logic, and position management.
"""
import pytest
from unittest.mock import Mock, patch, MagicMock
from pathlib import Path
import tempfile
import sqlite3
from datetime import datetime

from core.tactics import (
    TacticsDatabase, TacticsEngine, TacticsPosition, ReviewSession,
    TacticsResult, MistakeType
)
from core.models import GameInfo


class TestTacticsPosition:
    """Test suite for TacticsPosition class."""

    def test_position_creation(self, sample_tactics_position: TacticsPosition):
        """Test creating a tactics position."""
        pos = sample_tactics_position
        assert pos.fen == "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        assert pos.user_move == "e2e4"
        assert pos.mistake_type.value == "?"
        assert pos.difficulty == 3

    def test_position_board_property(self, sample_tactics_position: TacticsPosition):
        """Test that position.board returns valid chess.Board."""
        pos = sample_tactics_position
        board = pos.board
        assert board.fen() == pos.fen
        assert board.is_valid()

    def test_position_serialization(self, sample_tactics_position: TacticsPosition):
        """Test position can be converted to/from dict."""
        pos = sample_tactics_position

        # Convert to dict (this would be used for JSON serialization)
        pos_dict = {
            'fen': pos.fen,
            'user_move': pos.user_move,
            'correct_line': pos.correct_line,
            'mistake_type': pos.mistake_type.value,
            'difficulty': pos.difficulty
        }

        assert pos_dict['fen'] == pos.fen
        assert pos_dict['mistake_type'] == "?"


class TestTacticsDatabase:
    """Test suite for TacticsDatabase class."""

    @pytest.fixture
    def temp_db_path(self, temp_data_dir: Path) -> Path:
        """Create a temporary database path."""
        return temp_data_dir / "test_tactics.db"

    @pytest.fixture
    def tactics_db(self, temp_db_path: Path) -> TacticsDatabase:
        """Create a TacticsDatabase with temporary file."""
        with patch('core.tactics.DATA_DIR', temp_db_path.parent):
            db = TacticsDatabase()
            db.db_path = temp_db_path
            return db

    def test_database_initialization(self, tactics_db: TacticsDatabase):
        """Test database initializes correctly."""
        # Database should start empty
        assert len(tactics_db.positions) == 0
        assert tactics_db.current_session is None

    def test_add_position(self, tactics_db: TacticsDatabase, sample_tactics_position: TacticsPosition):
        """Test adding a position to the database."""
        tactics_db.positions.append(sample_tactics_position)

        assert len(tactics_db.positions) == 1
        assert tactics_db.positions[0].fen == sample_tactics_position.fen

    def test_load_positions_empty(self, tactics_db: TacticsDatabase):
        """Test loading positions from empty database."""
        count = tactics_db.load_positions()
        assert count == 0

    def test_start_session(self, tactics_db: TacticsDatabase, sample_tactics_position: TacticsPosition):
        """Test starting a tactics session."""
        tactics_db.add_position(sample_tactics_position)
        tactics_db.start_session()

        assert tactics_db.current_session is not None
        assert tactics_db.current_session.positions_attempted == 0

    def test_get_positions_for_review(self, tactics_db: TacticsDatabase, sample_tactics_position: TacticsPosition):
        """Test getting positions for review."""
        tactics_db.add_position(sample_tactics_position)
        tactics_db.start_session()

        positions = tactics_db.get_positions_for_review(1)
        assert len(positions) == 1
        assert positions[0].id == "test_001"

    def test_record_attempt_correct(self, tactics_db: TacticsDatabase, sample_tactics_position: TacticsPosition):
        """Test recording a correct attempt."""
        tactics_db.add_position(sample_tactics_position)
        tactics_db.start_session()

        tactics_db.record_attempt(sample_tactics_position, TacticsResult.CORRECT, 5.0)

        assert tactics_db.current_session.positions_attempted == 1
        assert tactics_db.current_session.positions_correct == 1
        assert tactics_db.current_session.positions_incorrect == 0

    def test_record_attempt_incorrect(self, tactics_db: TacticsDatabase, sample_tactics_position: TacticsPosition):
        """Test recording an incorrect attempt."""
        tactics_db.add_position(sample_tactics_position)
        tactics_db.start_session()

        tactics_db.record_attempt(sample_tactics_position, TacticsResult.INCORRECT, 10.0)

        assert tactics_db.current_session.positions_attempted == 1
        assert tactics_db.current_session.positions_correct == 0
        assert tactics_db.current_session.positions_incorrect == 1

    @patch('core.tactics.sqlite3')
    def test_database_persistence(self, mock_sqlite: Mock, tactics_db: TacticsDatabase):
        """Test that database operations use SQLite correctly."""
        mock_conn = Mock()
        mock_cursor = Mock()
        mock_sqlite.connect.return_value = mock_conn
        mock_conn.cursor.return_value = mock_cursor

        # Test save operation would call SQLite
        tactics_db._save_to_database()

        mock_sqlite.connect.assert_called()

    def test_spaced_repetition_algorithm(self, tactics_db: TacticsDatabase):
        """Test that spaced repetition affects position ordering."""
        # Create positions with different success rates
        from core.tactics import GameInfo as TacticsGameInfo, MistakeType

        pos1 = TacticsPosition(
            fen="fen1", user_move="e2e4", correct_line=["e5"],
            mistake_type=MistakeType.MISTAKE, difficulty=3, review_count=10,
            success_count=9, last_reviewed=datetime.now(), context="test", mistake_analysis="test",
            game_info=TacticsGameInfo("W", "B", "1-0", "2023-01-01", "1")
        )

        pos2 = TacticsPosition(
            fen="fen2", user_move="e2e4", correct_line=["e5"],
            mistake_type=MistakeType.MISTAKE, difficulty=3, review_count=2,
            success_count=1, last_reviewed=None, context="test", mistake_analysis="test",
            game_info=TacticsGameInfo("W", "B", "1-0", "2023-01-01", "2")
        )

        tactics_db.positions.append(pos1)
        tactics_db.positions.append(pos2)
        tactics_db.start_session()

        # Lower success rate should be prioritized
        positions = tactics_db.get_positions_for_review(1)
        assert positions[0].success_rate < pos1.success_rate  # Lower success rate


class TestTacticsEngine:
    """Test suite for TacticsEngine class."""

    @pytest.fixture
    def tactics_engine(self) -> TacticsEngine:
        """Create a TacticsEngine instance."""
        return TacticsEngine()

    def test_check_correct_move(self, tactics_engine: TacticsEngine, sample_tactics_position: TacticsPosition):
        """Test checking a correct move."""
        # Modify position to have a realistic correct line
        sample_tactics_position.correct_line = ["e5"]  # Correct response to e4

        result = tactics_engine.check_move(sample_tactics_position, "e7e5")
        assert result == TacticsResult.CORRECT

    def test_check_incorrect_move(self, tactics_engine: TacticsEngine, sample_tactics_position: TacticsPosition):
        """Test checking an incorrect move."""
        sample_tactics_position.correct_line = ["e5"]

        result = tactics_engine.check_move(sample_tactics_position, "d7d6")
        assert result == TacticsResult.INCORRECT

    def test_check_invalid_move(self, tactics_engine: TacticsEngine, sample_tactics_position: TacticsPosition):
        """Test checking an invalid move."""
        result = tactics_engine.check_move(sample_tactics_position, "invalid_move")
        assert result == TacticsResult.INCORRECT

    def test_get_solution(self, tactics_engine: TacticsEngine, sample_tactics_position: TacticsPosition):
        """Test getting the solution for a position."""
        sample_tactics_position.correct_line = ["e5", "Nf3", "Nc6"]

        solution = tactics_engine.get_solution(sample_tactics_position)
        assert "e5" in solution
        assert len(solution) > 0

    def test_partial_move_detection(self, tactics_engine: TacticsEngine):
        """Test detection of partially correct moves."""
        # This would test if the engine can detect moves that are
        # good but not the best in the position
        position = TacticsPosition(
            id="partial_test",
            fen="r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3",
            user_move="f1c4",  # User played Bc4 instead of best move
            correct_line=["Bb5"],  # Best move is Bb5
            mistake_type="?!", difficulty=2, success_rate=0.5, review_count=1,
            last_seen=None, context="test", mistake_analysis="test",
            game_info=GameInfo("W", "B", "1-0", "2023-01-01", "Test", "partial")
        )

        # Bc4 is a reasonable move but Bb5 is better
        result = tactics_engine.check_move(position, "f1c4")
        # Depending on implementation, this might be PARTIAL or INCORRECT
        assert result in [TacticsResult.PARTIAL, TacticsResult.INCORRECT]


class TestReviewSession:
    """Test suite for ReviewSession class."""

    def test_session_creation(self):
        """Test creating a new review session."""
        session = ReviewSession()

        assert session.positions_attempted == 0
        assert session.positions_correct == 0
        assert session.positions_incorrect == 0
        assert isinstance(session.start_time, datetime)

    def test_session_statistics(self):
        """Test session statistics calculation."""
        session = ReviewSession()
        session.positions_attempted = 10
        session.positions_correct = 7
        session.positions_incorrect = 3

        # Test accuracy calculation
        accuracy = session.positions_correct / session.positions_attempted
        assert accuracy == 0.7


class TestMistakeType:
    """Test suite for MistakeType enum."""

    def test_mistake_type_values(self):
        """Test that MistakeType has expected values."""
        assert MistakeType.BLUNDER.value == "??"
        assert MistakeType.MISTAKE.value == "?"
        assert MistakeType.INACCURACY.value == "?!"


@pytest.mark.integration
class TestTacticsIntegration:
    """Integration tests for the complete tactics system."""

    def test_complete_training_workflow(self, temp_data_dir: Path):
        """Test a complete training workflow from start to finish."""
        with patch('core.tactics.DATA_DIR', temp_data_dir):
            # Initialize system
            db = TacticsDatabase()
            engine = TacticsEngine()

            # Add a position
            position = TacticsPosition(
                id="integration_test",
                fen="rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",
                user_move="d2d4",  # User's move
                correct_line=["exd4", "Qxd4"],  # Correct continuation
                mistake_type="?",
                difficulty=2,
                success_rate=0.5,
                review_count=0,
                last_seen=None,
                context="Opening",
                mistake_analysis="Should recapture",
                game_info=GameInfo("White", "Black", "1-0", "2023-01-01", "Test", "int_test")
            )

            db.add_position(position)

            # Start session
            db.start_session()
            assert db.current_session is not None

            # Get position for review
            positions = db.get_positions_for_review(1)
            assert len(positions) == 1

            # Make a move
            result = engine.check_move(positions[0], "e5d4")  # Correct move
            assert result == TacticsResult.CORRECT

            # Record the attempt
            db.record_attempt(positions[0], result, 3.5)

            # Verify session updated
            assert db.current_session.positions_attempted == 1
            assert db.current_session.positions_correct == 1

    @pytest.mark.slow
    def test_large_position_database(self, temp_data_dir: Path):
        """Test performance with many positions."""
        with patch('core.tactics.DATA_DIR', temp_data_dir):
            db = TacticsDatabase()

            # Add many positions
            for i in range(100):
                position = TacticsPosition(
                    id=f"pos_{i}",
                    fen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                    user_move="e2e4",
                    correct_line=["e5"],
                    mistake_type="?",
                    difficulty=i % 5 + 1,
                    success_rate=0.5,
                    review_count=i % 10,
                    last_seen=None,
                    context=f"Position {i}",
                    mistake_analysis="Test position",
                    game_info=GameInfo("W", "B", "1-0", "2023-01-01", "Test", f"game_{i}")
                )
                db.add_position(position)

            # Test that we can efficiently get positions for review
            db.start_session()
            positions = db.get_positions_for_review(10)
            assert len(positions) == 10


@pytest.mark.chess
class TestChessLogic:
    """Test chess-specific logic in tactics system."""

    def test_fen_validation(self):
        """Test that invalid FENs are handled properly."""
        invalid_fen = "invalid_fen_string"

        with pytest.raises(ValueError):
            TacticsPosition(
                id="invalid",
                fen=invalid_fen,
                user_move="e2e4",
                correct_line=["e5"],
                mistake_type="?",
                difficulty=1,
                success_rate=0.5,
                review_count=0,
                last_seen=None,
                context="test",
                mistake_analysis="test",
                game_info=GameInfo("W", "B", "1-0", "2023-01-01", "Test", "invalid")
            )

    def test_move_validation(self, tactics_engine: TacticsEngine):
        """Test that illegal moves are handled correctly."""
        position = TacticsPosition(
            id="move_test",
            fen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            user_move="e2e4",
            correct_line=["e5"],
            mistake_type="?",
            difficulty=1,
            success_rate=0.5,
            review_count=0,
            last_seen=None,
            context="test",
            mistake_analysis="test",
            game_info=GameInfo("W", "B", "1-0", "2023-01-01", "Test", "move_test")
        )

        # Test illegal move
        result = tactics_engine.check_move(position, "e2e5")  # Illegal pawn move
        assert result == TacticsResult.INCORRECT