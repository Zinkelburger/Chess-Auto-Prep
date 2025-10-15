"""
Hybrid probability provider: uses Lichess API when available, falls back to Maia2.
"""

import chess
import sys
import os
from typing import Dict, Optional

# Add parent directory to path to import from lichess-opening-builder
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

# Import query function without importing the whole module (to avoid token check)
import requests
import time
from dotenv import load_dotenv

load_dotenv()

LICHESS_API_TOKEN = os.getenv("LICHESS_API_TOKEN")
BASE_URL = "https://explorer.lichess.ovh/lichess"
HEADERS = {"Authorization": f"Bearer {LICHESS_API_TOKEN}"} if LICHESS_API_TOKEN else {}

def query_lichess_api(fen: str):
    """Queries the Lichess API for a given FEN (using hardcoded ratings 1800-2500, blitz/rapid/classical)."""
    params = {
        "variant": "standard",
        "fen": fen,
        "ratings": "1800,2000,2200,2500",
        "speeds": "blitz,rapid,classical"
    }
    try:
        time.sleep(0.1)
        response = requests.get(BASE_URL, params=params, headers=HEADERS)

        if response.status_code == 429:
            print("    [!] Rate limited (429). Waiting 61 seconds...")
            time.sleep(61)
            return query_lichess_api(fen)

        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"    [!] Lichess API request failed: {e}")
        return None


class HybridProbability:
    """
    Provides move probabilities using Lichess API first, Maia2 as fallback.
    """

    def __init__(
        self,
        maia2_model,
        use_lichess: bool = True,
        lichess_min_games: int = 100,
        lichess_rating_range: Optional[tuple] = None,
        lichess_speeds: Optional[list] = None
    ):
        """
        Initialize hybrid probability provider.

        Args:
            maia2_model: Maia2 model instance (fallback)
            use_lichess: Whether to try Lichess API first
            lichess_min_games: Minimum games required from Lichess
            lichess_rating_range: Not used (parent API uses hardcoded ratings)
            lichess_speeds: Not used (parent API uses hardcoded speeds)
        """
        self.maia2 = maia2_model
        self.use_lichess = use_lichess
        self.lichess_min_games = lichess_min_games

    def get_move_probabilities(
        self,
        board: chess.Board,
        player_elo: int,
        opponent_elo: int,
        min_probability: float = 0.01
    ) -> Dict[str, float]:
        """
        Get move probabilities, trying Lichess first, then Maia2.

        Args:
            board: Current position
            player_elo: Player ELO (for Maia2 fallback)
            opponent_elo: Opponent ELO (for Maia2 fallback)
            min_probability: Minimum probability threshold

        Returns:
            Dictionary of {move_san: probability}
        """
        # Try Lichess API first if enabled
        if self.use_lichess:
            data = query_lichess_api(board.fen())

            if data and data.get('moves'):
                total_games = data.get('white', 0) + data.get('black', 0) + data.get('draws', 0)

                if total_games >= self.lichess_min_games:
                    # Calculate probabilities
                    move_probs = {}
                    total_move_count = sum(
                        m.get('white', 0) + m.get('draws', 0) + m.get('black', 0)
                        for m in data['moves']
                    )

                    if total_move_count > 0:
                        for move_data in data['moves']:
                            move_san = move_data.get('san')
                            if not move_san:
                                continue

                            games = move_data.get('white', 0) + move_data.get('draws', 0) + move_data.get('black', 0)
                            probability = games / total_move_count

                            if probability >= min_probability:
                                move_probs[move_san] = probability

                        if move_probs:
                            print(f"    [Lichess API] Found {len(move_probs)} moves from {total_games} games")
                            return move_probs

        # Fallback to Maia2
        print(f"    [Fallback] Using Maia2 @ {player_elo} ELO")
        return self.maia2.get_move_probabilities(
            board=board,
            player_elo=player_elo,
            opponent_elo=opponent_elo,
            min_probability=min_probability
        )
