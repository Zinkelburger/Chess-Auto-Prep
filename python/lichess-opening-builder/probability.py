"""
Probability providers for move predictions.

Provides move probabilities from:
- Lichess Explorer API (real game statistics)
- Maia2 neural network (human-like move predictions)
- Hybrid (Lichess with Maia2 fallback)
"""

import os
import time
from abc import ABC, abstractmethod
from typing import Dict, List, Optional, Any

import chess
import requests
from dotenv import load_dotenv

load_dotenv()


class ProbabilityProvider(ABC):
    """Abstract base class for move probability providers."""

    @abstractmethod
    def get_move_probabilities(
        self,
        board: chess.Board,
        player_elo: int = 2000,
        opponent_elo: int = 2000,
        min_probability: float = 0.01
    ) -> Dict[str, float]:
        """
        Get move probabilities for the current position.

        Args:
            board: Chess board position
            player_elo: ELO of the player to move
            opponent_elo: ELO of the opponent
            min_probability: Minimum probability to include

        Returns:
            Dictionary mapping SAN moves to probabilities
        """
        pass


class LichessProvider(ProbabilityProvider):
    """
    Provides move probabilities from the Lichess Explorer API.
    Uses real game statistics from the Lichess database.
    """

    BASE_URL = "https://explorer.lichess.ovh/lichess"

    def __init__(
        self,
        ratings: str = "1800,2000,2200,2500",
        speeds: str = "blitz,rapid,classical",
        min_games: int = 100
    ):
        """
        Initialize Lichess provider.

        Args:
            ratings: Comma-separated rating brackets
            speeds: Comma-separated game speeds
            min_games: Minimum games required for valid data
        """
        self.ratings = ratings
        self.speeds = speeds
        self.min_games = min_games
        
        token = os.getenv("LICHESS_API_TOKEN") or os.getenv("LICHESS")
        self.headers = {"Authorization": f"Bearer {token}"} if token else {}

    def query_api(self, fen: str) -> Optional[Dict[str, Any]]:
        """Query the Lichess Explorer API for a position."""
        params = {
            "variant": "standard",
            "fen": fen,
            "ratings": self.ratings,
            "speeds": self.speeds
        }
        
        try:
            time.sleep(0.1)  # Rate limiting
            response = requests.get(self.BASE_URL, params=params, headers=self.headers)

            if response.status_code == 429:
                print("    [!] Rate limited (429). Waiting 61 seconds...")
                time.sleep(61)
                return self.query_api(fen)

            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            print(f"    [!] Lichess API request failed: {e}")
            return None

    def get_move_probabilities(
        self,
        board: chess.Board,
        player_elo: int = 2000,
        opponent_elo: int = 2000,
        min_probability: float = 0.01
    ) -> Dict[str, float]:
        """Get move probabilities from Lichess game statistics."""
        data = self.query_api(board.fen())
        
        if not data or not data.get("moves"):
            return {}

        total_games = data.get("white", 0) + data.get("black", 0) + data.get("draws", 0)
        if total_games < self.min_games:
            return {}  # Will trigger Maia fallback in HybridProvider

        # Calculate probabilities
        move_probs = {}
        total_move_games = sum(
            m.get("white", 0) + m.get("draws", 0) + m.get("black", 0)
            for m in data["moves"]
        )

        if total_move_games == 0:
            return {}

        for move_data in data["moves"]:
            move_san = move_data.get("san")
            if not move_san:
                continue

            games = move_data.get("white", 0) + move_data.get("draws", 0) + move_data.get("black", 0)
            probability = games / total_move_games

            if probability >= min_probability:
                move_probs[move_san] = probability

        return move_probs

    def get_position_data(self, board: chess.Board) -> Optional[Dict[str, Any]]:
        """
        Get full position data from Lichess API.
        
        Returns the raw API response including move statistics,
        total games, win/draw/loss counts, etc.
        """
        return self.query_api(board.fen())


class Maia2Provider(ProbabilityProvider):
    """
    Provides move probabilities from the Maia2 neural network.
    Predicts what moves humans are likely to play at different skill levels.
    """

    def __init__(
        self,
        game_type: str = "rapid",
        device: str = "cpu",
        default_elo: int = 2000
    ):
        """
        Initialize Maia2 model.

        Args:
            game_type: Either "rapid" or "blitz"
            device: Either "cpu" or "gpu"
            default_elo: Default ELO rating for predictions
        """
        from maia2 import model, inference
        
        self.game_type = game_type
        self.device = device
        self.default_elo = default_elo

        print(f"Loading Maia2 model ({game_type}, {device})...")
        self.model = model.from_pretrained(type=game_type, device=device)
        self.prepared = inference.prepare()
        self._inference = inference
        print("Maia2 model loaded!")

    def get_move_probabilities(
        self,
        board: chess.Board,
        player_elo: int = None,
        opponent_elo: int = None,
        min_probability: float = 0.01
    ) -> Dict[str, float]:
        """Get move probabilities from Maia2 neural network."""
        if player_elo is None:
            player_elo = self.default_elo
        if opponent_elo is None:
            opponent_elo = self.default_elo

        # Get predictions from Maia2
        move_probs_raw, _ = self._inference.inference_each(
            self.model,
            self.prepared,
            board.fen(),
            player_elo,
            opponent_elo
        )

        # Convert UCI moves to SAN and filter
        san_probs = {}
        for uci_move, prob in move_probs_raw.items():
            if prob < min_probability:
                continue

            try:
                move = chess.Move.from_uci(uci_move)
                if move in board.legal_moves:
                    san = board.san(move)
                    san_probs[san] = prob
            except (ValueError, chess.IllegalMoveError):
                continue

        return san_probs


class HybridProvider(ProbabilityProvider):
    """
    Hybrid provider that uses Lichess API when available,
    falling back to Maia2 for positions with insufficient data.
    """

    def __init__(
        self,
        maia_provider: Maia2Provider,
        lichess_provider: LichessProvider = None
    ):
        """
        Initialize hybrid provider.

        Args:
            maia_provider: Maia2 provider for fallback
            lichess_provider: Lichess provider (created if not provided)
        """
        self.maia = maia_provider
        self.lichess = lichess_provider or LichessProvider()

    def get_move_probabilities(
        self,
        board: chess.Board,
        player_elo: int = 2000,
        opponent_elo: int = 2000,
        min_probability: float = 0.01
    ) -> Dict[str, float]:
        """Get probabilities from Lichess, falling back to Maia2 if < min_games."""
        # Try Lichess first
        data = self.lichess.get_position_data(board)
        total_games = 0
        if data:
            total_games = data.get("white", 0) + data.get("black", 0) + data.get("draws", 0)
        
        # Use Lichess if we have enough games
        if total_games >= self.lichess.min_games:
            move_probs = self.lichess.get_move_probabilities(
                board, player_elo, opponent_elo, min_probability
            )
            if move_probs:
                print(f"    [Lichess] {len(move_probs)} moves from {total_games} games")
                return move_probs

        # Fallback to Maia2 (not enough games in database)
        if total_games > 0:
            print(f"    [Maia2] Only {total_games} games in DB (< {self.lichess.min_games}), using Maia @ {player_elo} ELO")
        else:
            print(f"    [Maia2] No DB data, using Maia @ {player_elo} ELO")
        
        return self.maia.get_move_probabilities(
            board, player_elo, opponent_elo, min_probability
        )


def create_provider(args) -> ProbabilityProvider:
    """
    Factory function to create the appropriate probability provider.

    Args:
        args: Parsed command-line arguments

    Returns:
        Configured probability provider
    """
    lichess = LichessProvider(
        ratings=args.lichess_ratings,
        speeds=args.lichess_speeds,
        min_games=args.lichess_min_games
    )

    # For tricks mode, default to using Maia2 (with Lichess fallback)
    if args.mode == "tricks" or args.use_maia:
        maia = Maia2Provider(
            game_type=args.maia_type,
            device=args.device,
            default_elo=args.player_elo
        )
        return HybridProvider(maia_provider=maia, lichess_provider=lichess)

    # For pressure mode, use Lichess with Maia2 fallback when database runs out
    if args.mode == "pressure":
        try:
            maia = Maia2Provider(
                game_type=args.maia_type,
                device=args.device,
                default_elo=args.opponent_elo
            )
            return HybridProvider(maia_provider=maia, lichess_provider=lichess)
        except Exception as e:
            print(f"    [!] Maia2 not available ({e}), using Lichess only")
            return lichess

    # For coverage mode, just use Lichess
    return lichess

