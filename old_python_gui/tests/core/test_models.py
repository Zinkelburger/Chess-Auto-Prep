"""
Tests for core.models module.
Tests the main data model classes and their functionality.
"""
import pytest
from pathlib import Path
from unittest.mock import Mock, patch

from core.models import PositionStats, GameInfo, PositionAnalysis


class TestPositionStats:
    """Test suite for PositionStats class."""

    def test_position_stats_creation(self):
        """Test creating a PositionStats object."""
        stats = PositionStats(
            fen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            games=10,
            wins=6,
            losses=2,
            draws=2
        )

        assert stats.fen == "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        assert stats.games == 10
        assert stats.wins == 6
        assert stats.losses == 2
        assert stats.draws == 2

    def test_win_rate_calculation(self):
        """Test win rate calculation."""
        stats = PositionStats(
            fen="test_fen",
            games=10,
            wins=6,
            losses=2,
            draws=2
        )

        # Win rate = (wins + 0.5 * draws) / games = (6 + 0.5 * 2) / 10 = 0.7
        assert stats.win_rate == 0.7
        assert stats.win_rate_percent == 70.0

    def test_win_rate_zero_games(self):
        """Test win rate with zero games."""
        stats = PositionStats(fen="test_fen")
        assert stats.win_rate == 0.0
        assert stats.win_rate_percent == 0.0

    def test_default_values(self):
        """Test default values for PositionStats."""
        stats = PositionStats(fen="test_fen")
        assert stats.games == 0
        assert stats.wins == 0
        assert stats.losses == 0
        assert stats.draws == 0
        assert len(stats.game_urls) == 0


class TestGameInfo:
    """Test suite for GameInfo class."""

    def test_game_info_creation(self):
        """Test creating a GameInfo object."""
        game_info = GameInfo(
            white="Player A",
            black="Player B",
            result="1-0",
            date="2023.01.01",
            site="Chess.com",
            event="Casual Game"
        )

        assert game_info.white == "Player A"
        assert game_info.black == "Player B"
        assert game_info.result == "1-0"
        assert game_info.date == "2023.01.01"
        assert game_info.site == "Chess.com"
        assert game_info.event == "Casual Game"

    def test_game_info_defaults(self):
        """Test default values for GameInfo."""
        game_info = GameInfo()
        assert game_info.white == ""
        assert game_info.black == ""
        assert game_info.result == ""
        assert game_info.date == ""
        assert game_info.site == ""
        assert game_info.event == ""
        assert game_info.pgn_path is None
        assert game_info.pgn_text is None

    @patch('chess.pgn.read_game')
    def test_pgn_text_parsing(self, mock_read_game):
        """Test parsing PGN text in GameInfo."""
        # Mock a chess game
        mock_game = Mock()
        mock_game.headers = {
            'White': 'Test White',
            'Black': 'Test Black',
            'Result': '1-0',
            'Date': '2023.01.01'
        }
        mock_read_game.return_value = mock_game

        pgn_text = '''[White "Test White"]
[Black "Test Black"]
[Result "1-0"]
[Date "2023.01.01"]

1. e4 e5 2. Nf3 1-0'''

        game_info = GameInfo(pgn_text=pgn_text)

        # Should have called the parsing
        assert mock_read_game.called
        assert game_info.white == "Test White"
        assert game_info.black == "Test Black"
        assert game_info.result == "1-0"
        assert game_info.date == "2023.01.01"


class TestPositionAnalysis:
    """Test suite for PositionAnalysis class."""

    def test_position_analysis_creation(self):
        """Test creating a PositionAnalysis object."""
        analysis = PositionAnalysis()

        assert len(analysis.position_stats) == 0
        assert len(analysis.games) == 0
        assert len(analysis.fen_to_game_indices) == 0

    def test_add_position_stats(self):
        """Test adding position statistics."""
        analysis = PositionAnalysis()
        stats = PositionStats(fen="test_fen", games=5, wins=3, losses=1, draws=1)

        analysis.add_position_stats(stats)

        assert len(analysis.position_stats) == 1
        assert "test_fen" in analysis.position_stats
        assert analysis.position_stats["test_fen"] == stats

    def test_add_game(self):
        """Test adding a game and getting its index."""
        analysis = PositionAnalysis()
        game = GameInfo(white="Player A", black="Player B", result="1-0")

        index = analysis.add_game(game)

        assert index == 0
        assert len(analysis.games) == 1
        assert analysis.games[0] == game

    def test_multiple_games(self):
        """Test adding multiple games."""
        analysis = PositionAnalysis()
        game1 = GameInfo(white="A", black="B", result="1-0")
        game2 = GameInfo(white="C", black="D", result="0-1")

        index1 = analysis.add_game(game1)
        index2 = analysis.add_game(game2)

        assert index1 == 0
        assert index2 == 1
        assert len(analysis.games) == 2


@pytest.mark.unit
class TestModelsIntegration:
    """Integration tests for models module."""

    def test_position_stats_with_game_urls(self):
        """Test PositionStats with game URLs."""
        urls = ["https://lichess.org/game1", "https://lichess.org/game2"]
        stats = PositionStats(
            fen="test_fen",
            games=2,
            wins=1,
            losses=1,
            game_urls=urls
        )

        assert len(stats.game_urls) == 2
        assert stats.game_urls == urls

    def test_comprehensive_game_info(self):
        """Test GameInfo with all fields."""
        game_info = GameInfo(
            pgn_path=Path("/test/game.pgn"),
            white="Grandmaster A",
            black="Grandmaster B",
            result="0-1",
            date="2023.12.25",
            site="World Championship",
            event="Final Match"
        )

        assert isinstance(game_info.pgn_path, Path)
        assert game_info.pgn_path.name == "game.pgn"
        assert game_info.white == "Grandmaster A"
        assert game_info.event == "Final Match"