"""
Pytest configuration and shared fixtures for Chess Auto-Prep tests.
"""
import pytest
import tempfile
import shutil
from pathlib import Path
from unittest.mock import Mock, MagicMock
from typing import Generator, Any

import chess
import chess.pgn
import io

# Import project modules
from core.tactics import TacticsDatabase, TacticsEngine, TacticsPosition, GameInfo as TacticsGameInfo
from core.pgn_processor import PGNProcessor, GameData, MoveData
from core.models import GameInfo, PositionAnalysis


@pytest.fixture(scope="session")
def temp_data_dir() -> Generator[Path, None, None]:
    """Create a temporary directory for test data."""
    temp_dir = tempfile.mkdtemp(prefix="chess_auto_prep_test_")
    yield Path(temp_dir)
    shutil.rmtree(temp_dir)


@pytest.fixture
def sample_pgn() -> str:
    """Provide a sample PGN with annotations for testing."""
    return '''[Event "Test Game"]
[Site "Test"]
[Date "2023.01.01"]
[Round "1"]
[White "Player A"]
[Black "Player B"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6?! { Inaccuracy. Be7 was best. } 4. Ba4 Nf6
5. O-O Be7 6. Re1 b5 7. Bb3 d6 8. c3 O-O 9. h3 Nb8 10. d4 Nbd7
11. c4 c6 12. cxb5 axb5 13. Nc3 Bb7 14. Bg5 b4 15. Nb1 h6 16. Bh4 c5
17. dxe5 Nxe5? { Mistake. dxe5 was best. } 18. Nxe5 Bxe4 19. Qf3 Bg6
20. Qxa8 Qxa8 21. Rxa8+ Rxa8 22. Nxg6 fxg6 1-0'''


@pytest.fixture
def sample_game_data(sample_pgn: str) -> GameData:
    """Provide parsed GameData for testing."""
    processor = PGNProcessor()
    return processor.parse_pgn(sample_pgn)


@pytest.fixture
def sample_chess_game(sample_pgn: str) -> chess.pgn.Game:
    """Provide a chess.pgn.Game object for testing."""
    return chess.pgn.read_game(io.StringIO(sample_pgn))


@pytest.fixture
def mock_tactics_database() -> Mock:
    """Provide a mocked TacticsDatabase."""
    db = Mock(spec=TacticsDatabase)
    db.positions = []
    db.current_session = Mock()
    db.current_session.positions_attempted = 0
    db.current_session.positions_correct = 0
    db.current_session.positions_incorrect = 0
    return db


@pytest.fixture
def mock_tactics_engine() -> Mock:
    """Provide a mocked TacticsEngine."""
    engine = Mock(spec=TacticsEngine)
    return engine


@pytest.fixture
def sample_tactics_position() -> TacticsPosition:
    """Provide a sample tactics position for testing."""
    from core.tactics import MistakeType
    return TacticsPosition(
        fen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        user_move="e2e4",
        correct_line=["e5", "Nf3", "Nc6"],
        mistake_type=MistakeType.MISTAKE,
        difficulty=3,
        review_count=5,
        success_count=4,
        last_reviewed=None,
        context="Opening position",
        mistake_analysis="This is a test mistake",
        game_info=TacticsGameInfo(
            white="Test White",
            black="Test Black",
            result="1-0",
            date="2023-01-01",
            game_id="test_game_001"
        )
    )


@pytest.fixture
def sample_board_positions():
    """Provide various chess board positions for testing."""
    return {
        'starting': 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        'after_e4': 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
        'sicilian': 'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2',
        'endgame': '8/8/8/8/8/8/4K3/4k3 w - - 0 1',
        'checkmate': 'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3'
    }


@pytest.fixture
def pgn_processor() -> PGNProcessor:
    """Provide a fresh PGNProcessor instance."""
    return PGNProcessor()


@pytest.fixture(autouse=True)
def reset_chess_state():
    """Reset any global chess state between tests."""
    yield
    # Clean up any global state if needed


# Test data generators using Hypothesis
@pytest.fixture
def chess_position_strategy():
    """Hypothesis strategy for generating valid chess positions."""
    try:
        from hypothesis import strategies as st

        # Generate FEN strings for valid chess positions
        return st.sampled_from([
            'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
            'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
            'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2',
            'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3',
        ])
    except ImportError:
        return None


# Mock Qt Application for UI tests
@pytest.fixture
def qapp():
    """Provide a QApplication instance for UI tests."""
    try:
        from PySide6.QtWidgets import QApplication
        import sys

        app = QApplication.instance()
        if app is None:
            app = QApplication(sys.argv)
        yield app
        # Don't quit the app as it might be used by other tests
    except ImportError:
        pytest.skip("PySide6 not available for UI tests")


# Performance testing fixtures
@pytest.fixture
def benchmark_pgn():
    """Provide a large PGN for performance testing."""
    # Generate a PGN with many moves for benchmarking
    moves = []
    for i in range(1, 51):  # 100 moves total
        moves.append(f"{i}. Move{i}")
        if i < 50:
            moves.append(f"Response{i}")

    return f'''[Event "Benchmark Game"]
[Site "Test"]
[Date "2023.01.01"]
[Round "1"]
[White "Player A"]
[Black "Player B"]
[Result "*"]

{" ".join(moves)} *'''