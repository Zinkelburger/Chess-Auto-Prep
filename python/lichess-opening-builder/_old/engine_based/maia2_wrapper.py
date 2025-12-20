"""
Maia2 wrapper for getting human move probabilities.

Uses the maia2 pip package (not UCI).
"""

import chess
from typing import Dict, Tuple
from maia2 import model, inference


class Maia2:
    """
    Wrapper for Maia2 to get human move probabilities at different skill levels.
    """

    def __init__(self, game_type: str = "rapid", device: str = "cpu", default_elo: int = 2000):
        """
        Initialize Maia2 model.

        Args:
            game_type: Either "rapid" or "blitz"
            device: Either "cpu" or "gpu"
            default_elo: Default ELO rating for both players (default: 2000)
        """
        self.game_type = game_type
        self.device = device
        self.default_elo = default_elo

        print(f"Loading Maia2 model ({game_type}, {device})...")
        self.model = model.from_pretrained(type=game_type, device=device)
        self.prepared = inference.prepare()
        print("Maia2 model loaded!")

    def get_move_probabilities(
        self,
        board: chess.Board,
        player_elo: int = None,
        opponent_elo: int = None,
        min_probability: float = 0.01
    ) -> Dict[str, float]:
        """
        Get move probabilities for the current position.

        Args:
            board: Chess board position
            player_elo: ELO of the player to move (default: self.default_elo)
            opponent_elo: ELO of the opponent (default: self.default_elo)
            min_probability: Minimum probability to include in results

        Returns:
            Dictionary mapping SAN moves to probabilities
        """
        if player_elo is None:
            player_elo = self.default_elo
        if opponent_elo is None:
            opponent_elo = self.default_elo

        fen = board.fen()

        # Get move probabilities and win probability from Maia2
        # win_prob is the probability that the player to move will win
        move_probs, win_prob = inference.inference_each(
            self.model,
            self.prepared,
            fen,
            player_elo,
            opponent_elo
        )

        # Convert UCI moves to SAN and filter by probability
        san_probs = {}
        for uci_move, prob in move_probs.items():
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

    def get_win_probability(
        self,
        board: chess.Board,
        player_elo: int = None,
        opponent_elo: int = None
    ) -> float:
        """
        Get the win probability for the player to move.

        Args:
            board: Chess board position
            player_elo: ELO of the player to move (default: self.default_elo)
            opponent_elo: ELO of the opponent (default: self.default_elo)

        Returns:
            Win probability (0.0 to 1.0) for the player to move
        """
        if player_elo is None:
            player_elo = self.default_elo
        if opponent_elo is None:
            opponent_elo = self.default_elo

        fen = board.fen()

        # Get win probability from Maia2
        _, win_prob = inference.inference_each(
            self.model,
            self.prepared,
            fen,
            player_elo,
            opponent_elo
        )

        return win_prob

    def get_top_moves(
        self,
        board: chess.Board,
        top_n: int = 5,
        player_elo: int = None,
        opponent_elo: int = None
    ) -> list[Tuple[str, float]]:
        """
        Get the top N most likely moves.

        Args:
            board: Chess board position
            top_n: Number of top moves to return
            player_elo: ELO of the player to move
            opponent_elo: ELO of the opponent

        Returns:
            List of (move_san, probability) tuples, sorted by probability descending
        """
        move_probs = self.get_move_probabilities(board, player_elo, opponent_elo)

        # Sort by probability and take top N
        sorted_moves = sorted(move_probs.items(), key=lambda x: x[1], reverse=True)
        return sorted_moves[:top_n]
