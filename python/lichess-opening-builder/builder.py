"""
Opening repertoire builder.

Supports two modes:
- coverage: Build complete repertoire covering all common opponent responses
- tricks: Find tricky lines where opponent is likely to blunder
"""

from dataclasses import dataclass
from typing import List, Optional, Dict, Any

import chess

from probability import ProbabilityProvider, LichessProvider
from evaluation import UCIEngine
from move_selectors import MoveSelector
from output import PgnWriter


@dataclass
class InterestingPosition:
    """A position found in tricks mode with good expected value."""
    line: List[str]
    fen: str
    probability: float
    expected_value: float


class RepertoireBuilder:
    """
    Builds chess opening repertoires.

    Coverage mode: Explores all opponent responses above a probability threshold.
    Tricks mode: Finds positions where opponent is likely to make mistakes.
    """

    def __init__(
        self,
        my_color: chess.Color,
        probability_provider: ProbabilityProvider,
        pgn_writer: PgnWriter,
        move_selector: Optional[MoveSelector] = None,
        engine: Optional[UCIEngine] = None,
        min_move_frequency: float = 0.005,
        min_position_games: int = 100
    ):
        """
        Initialize the builder.

        Args:
            my_color: Your color
            probability_provider: Provider for move probabilities
            pgn_writer: Writer for PGN output
            move_selector: Strategy for selecting your moves (coverage mode)
            engine: Stockfish engine (tricks mode)
            min_move_frequency: Minimum frequency for a move to be considered
            min_position_games: Minimum games in a position to explore
        """
        self.my_color = my_color
        self.probability_provider = probability_provider
        self.pgn_writer = pgn_writer
        self.move_selector = move_selector
        self.engine = engine
        self.min_move_frequency = min_move_frequency
        self.min_position_games = min_position_games
        self.completed_lines_count = 0

        # For Lichess API access in coverage mode
        if isinstance(probability_provider, LichessProvider):
            self.lichess = probability_provider
        else:
            self.lichess = LichessProvider()

    # =========================================================================
    # COVERAGE MODE
    # =========================================================================

    def build_coverage(
        self,
        start_board: chess.Board,
        threshold: float,
        initial_moves: Optional[List[str]] = None
    ):
        """
        Build a complete repertoire covering all common lines.

        Args:
            start_board: Starting position
            threshold: Minimum path probability to explore
            initial_moves: Moves already played to reach start position
        """
        initial_moves = initial_moves or []
        self._coverage_dfs(
            fen=start_board.fen(),
            path_probability=1.0,
            threshold=threshold,
            current_line=initial_moves
        )

    def _coverage_dfs(
        self,
        fen: str,
        path_probability: float,
        threshold: float,
        current_line: List[str]
    ):
        """Depth-first search for coverage mode."""
        board = chess.Board(fen)
        is_my_turn = board.turn == self.my_color

        # Game over check
        if board.is_game_over():
            self._save_line(current_line, path_probability, "Game over")
            return

        # Get position data from Lichess
        data = self.lichess.get_position_data(board)
        if not data or not data.get("moves"):
            self._save_line(current_line, path_probability, "No data")
            return

        total_games = data["white"] + data["black"] + data["draws"]
        if total_games < self.min_position_games:
            self._save_line(current_line, path_probability, f"Few games ({total_games})")
            return

        print(f"\n{'Me' if is_my_turn else 'Opp'} | Prob: {path_probability:.2%} | {' '.join(current_line) or 'Start'}")

        # Filter moves by frequency
        filtered_moves = []
        for move in data["moves"]:
            move_games = move["white"] + move["black"] + move["draws"]
            frequency = move_games / total_games

            if frequency >= self.min_move_frequency:
                filtered_moves.append(move)

        if not filtered_moves:
            self._save_line(current_line, path_probability, "No moves above frequency threshold")
            return

        if is_my_turn:
            # MY TURN: Pick one move (path probability unchanged)
            my_move = self.move_selector.select_move(filtered_moves, board, self.my_color)
            if not my_move:
                self._save_line(current_line, path_probability, "No valid move")
                return

            move_games = my_move["white"] + my_move["black"] + my_move["draws"]
            freq = move_games / total_games
            print(f"  -> {my_move['san']} ({freq:.1%}, {move_games} games)")

            board.push_san(my_move["san"])
            self._coverage_dfs(
                fen=board.fen(),
                path_probability=path_probability,  # Unchanged - we always play this
                threshold=threshold,
                current_line=current_line + [my_move["san"]]
            )
        else:
            # OPPONENT TURN: Explore all moves above cumulative threshold
            valid_opponent_moves = []
            for move in filtered_moves:
                move_games = move["white"] + move["black"] + move["draws"]
                conditional_prob = move_games / total_games
                new_path_prob = path_probability * conditional_prob

                if new_path_prob >= threshold:
                    valid_opponent_moves.append((move, conditional_prob, new_path_prob))
                else:
                    print(f"    [PRUNE] {move['san']}: {new_path_prob:.2%} < {threshold:.2%}")

            if not valid_opponent_moves:
                self._save_line(current_line, path_probability, "No opponent moves above threshold")
                return

            for move, cond_prob, new_path_prob in valid_opponent_moves:
                move_games = move["white"] + move["black"] + move["draws"]
                print(f"  -> {move['san']} ({cond_prob:.1%}, cumulative: {new_path_prob:.2%})")

                new_board = chess.Board(fen)
                new_board.push_san(move["san"])
                self._coverage_dfs(
                    fen=new_board.fen(),
                    path_probability=new_path_prob,
                    threshold=threshold,
                    current_line=current_line + [move["san"]]
                )

    # =========================================================================
    # TRICKS MODE
    # =========================================================================

    def build_tricks(
        self,
        start_board: chess.Board,
        player_elo: int,
        opponent_elo: int,
        min_ev: float = 50.0,
        max_depth: int = 20,
        min_probability: float = 0.10,
        top_candidates: int = 8,
        my_move_threshold_cp: float = 50.0,
        opponent_min_prob: float = 0.10,
        max_lines: int = 50,
        initial_moves: Optional[List[str]] = None
    ) -> List[InterestingPosition]:
        """
        Find tricky lines where opponent is likely to blunder.

        Args:
            start_board: Starting position
            player_elo: Your ELO for probability predictions
            opponent_elo: Opponent ELO for probability predictions
            min_ev: Minimum expected value to save a line
            max_depth: Maximum search depth
            min_probability: Minimum probability for moves
            top_candidates: Top N moves to evaluate for your moves
            my_move_threshold_cp: Consider your moves within this cp of best
            opponent_min_prob: Minimum probability for opponent moves
            max_lines: Maximum lines to output
            initial_moves: Moves already played to reach position

        Returns:
            List of interesting positions found
        """
        if not self.engine:
            raise ValueError("Engine required for tricks mode")

        initial_moves = initial_moves or []

        # Get root evaluation
        root_eval = self.engine.evaluate(start_board, depth=20, pov_color=self.my_color)
        if root_eval is None:
            root_eval = 0.0
        print(f"  Root eval: {root_eval:+.1f} cp")

        positions = self._tricks_search(
            board=start_board,
            player_elo=player_elo,
            opponent_elo=opponent_elo,
            min_ev=min_ev,
            max_depth=max_depth,
            min_probability=min_probability,
            top_candidates=top_candidates,
            my_move_threshold_cp=my_move_threshold_cp,
            opponent_min_prob=opponent_min_prob,
            current_depth=0,
            current_line=initial_moves,
            current_probability=1.0,
            root_eval=root_eval
        )

        # Sort by expected value
        positions.sort(key=lambda x: x.expected_value, reverse=True)
        return positions[:max_lines]

    def _tricks_search(
        self,
        board: chess.Board,
        player_elo: int,
        opponent_elo: int,
        min_ev: float,
        max_depth: int,
        min_probability: float,
        top_candidates: int,
        my_move_threshold_cp: float,
        opponent_min_prob: float,
        current_depth: int,
        current_line: List[str],
        current_probability: float,
        root_eval: float
    ) -> List[InterestingPosition]:
        """Recursive search for tricks mode."""
        interesting = []

        # Depth limit
        if current_depth >= max_depth:
            return interesting

        # Probability cutoff
        if current_probability < min_probability * 0.01:
            return interesting

        is_my_turn = board.turn == self.my_color

        # Get move probabilities
        if is_my_turn:
            current_elo, opposing_elo = player_elo, opponent_elo
        else:
            current_elo, opposing_elo = opponent_elo, player_elo

        move_probs = self.probability_provider.get_move_probabilities(
            board,
            player_elo=current_elo,
            opponent_elo=opposing_elo,
            min_probability=min_probability
        )

        if not move_probs:
            return interesting

        sorted_moves = sorted(move_probs.items(), key=lambda x: x[1], reverse=True)

        # Evaluate candidates
        children_data = []

        if is_my_turn:
            # MY TURN: Evaluate top candidates, keep within threshold of best
            candidates = sorted_moves[:top_candidates]
            evaluated = []

            for move_san, prob in candidates:
                child_board = board.copy()
                child_board.push_san(move_san)
                child_eval = self.engine.evaluate(child_board, depth=20, pov_color=self.my_color)
                if child_eval is None:
                    child_eval = 0.0
                evaluated.append((move_san, prob, child_eval, child_board))

            if not evaluated:
                return interesting

            best_eval = max(ev for _, _, ev, _ in evaluated)

            for move_san, prob, child_eval, child_board in evaluated:
                if child_eval >= best_eval - my_move_threshold_cp:
                    children_data.append((move_san, prob, child_eval, child_board))

        else:
            # OPPONENT TURN: All moves with probability >= threshold
            for move_san, prob in sorted_moves:
                if prob < opponent_min_prob:
                    break

                child_board = board.copy()
                child_board.push_san(move_san)
                child_eval = self.engine.evaluate(child_board, depth=20, pov_color=self.my_color)
                if child_eval is None:
                    child_eval = 0.0
                children_data.append((move_san, prob, child_eval, child_board))

        if not children_data:
            return interesting

        # Calculate expected value
        total_prob = sum(prob for _, prob, _, _ in children_data)
        expected_value = sum(prob * ev for _, prob, ev, _ in children_data) / total_prob

        # Check if this is an interesting opponent position
        if not is_my_turn and current_depth > 0:
            if expected_value >= min_ev:
                interesting.append(InterestingPosition(
                    line=current_line.copy(),
                    fen=board.fen(),
                    probability=current_probability,
                    expected_value=expected_value
                ))
                print(f"  [FOUND] {current_probability:.1%} | EV {expected_value:+.0f} | {' '.join(current_line)}")
                return interesting  # Stop - found what we wanted

        # Recurse into children
        for move_san, prob, _, child_board in children_data:
            child_probability = current_probability * prob
            if child_probability < min_probability * 0.01:
                continue

            child_positions = self._tricks_search(
                board=child_board,
                player_elo=player_elo,
                opponent_elo=opponent_elo,
                min_ev=min_ev,
                max_depth=max_depth,
                min_probability=min_probability,
                top_candidates=top_candidates,
                my_move_threshold_cp=my_move_threshold_cp,
                opponent_min_prob=opponent_min_prob,
                current_depth=current_depth + 1,
                current_line=current_line + [move_san],
                current_probability=child_probability,
                root_eval=root_eval
            )
            interesting.extend(child_positions)

        return interesting

    # =========================================================================
    # EVALUATION ONLY
    # =========================================================================

    def evaluate_position(
        self,
        board: chess.Board,
        player_elo: int,
        opponent_elo: int
    ):
        """
        Evaluate a single position and show all children with probabilities and evals.
        """
        if not self.engine:
            raise ValueError("Engine required for position evaluation")

        print("\n" + "=" * 70)
        print("POSITION EVALUATION")
        print("=" * 70)
        print(f"FEN: {board.fen()}")
        print(f"Turn: {'White' if board.turn == chess.WHITE else 'Black'}")

        current_eval = self.engine.evaluate(board, depth=20, pov_color=self.my_color)
        if current_eval is None:
            current_eval = 0.0
        print(f"Current eval: {current_eval:+.1f} cp (from your perspective)")

        is_my_turn = board.turn == self.my_color
        if is_my_turn:
            elo_to_move, elo_opponent = player_elo, opponent_elo
        else:
            elo_to_move, elo_opponent = opponent_elo, player_elo

        move_probs = self.probability_provider.get_move_probabilities(
            board,
            player_elo=elo_to_move,
            opponent_elo=elo_opponent,
            min_probability=0.001
        )

        if not move_probs:
            print("\nNo legal moves found.")
            return

        sorted_moves = sorted(move_probs.items(), key=lambda x: x[1], reverse=True)
        print(f"\n{'Your' if is_my_turn else 'Opponent'} moves (predicted @ {elo_to_move} ELO):")
        print("-" * 70)

        children_data = []
        for move_san, prob in sorted_moves:
            child_board = board.copy()
            child_board.push_san(move_san)
            child_eval = self.engine.evaluate(child_board, depth=20, pov_color=self.my_color)
            if child_eval is None:
                child_eval = 0.0
            children_data.append((move_san, prob, child_eval))
            print(f"  {move_san:8s}  Prob: {prob:6.1%}  Eval: {child_eval:+7.1f} cp")

        total_prob = sum(prob for _, prob, _ in children_data)
        expected_value = sum(prob * ev for _, prob, ev in children_data) / total_prob

        print("\n" + "-" * 70)
        if is_my_turn:
            best_eval = max(ev for _, _, ev in children_data)
            print(f"Best move eval:     {best_eval:+.1f} cp")
            print(f"Expected value:     {expected_value:+.1f} cp")
            print(f"Your mistake cost:  {best_eval - expected_value:+.1f} cp")
        else:
            best_defense = min(ev for _, _, ev in children_data)
            print(f"Best defense:       {best_defense:+.1f} cp")
            print(f"Expected value:     {expected_value:+.1f} cp")
            print(f"Their mistake gain: {expected_value - best_defense:+.1f} cp")
        print("=" * 70)

    # =========================================================================
    # HELPERS
    # =========================================================================

    def _save_line(self, moves: List[str], probability: float, reason: str):
        """Save a completed repertoire line."""
        self.completed_lines_count += 1
        self.pgn_writer.save_line(moves, probability, self.my_color)
        print(f"    ✓ [LINE {self.completed_lines_count}] {' '.join(moves) if moves else '(start)'} | {reason}")

