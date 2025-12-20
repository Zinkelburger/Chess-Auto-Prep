"""
Sustained Pressure Analysis for Chess Repertoires.

Builds a tree, calculates Ease at each node, then flattens to lines
sorted by "sustained pressure" (product of opponent Ease scores).

Lower survival = trickier line for opponent.
"""

import math
import random
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

import chess

from probability import LichessProvider, ProbabilityProvider
from evaluation import UCIEngine


# === Ease Calculation Parameters ===
ALPHA = 1/3
BETA = 1.5


@dataclass
class TreeNode:
    """A node in the exploration tree."""
    fen: str
    move_san: Optional[str] = None  # Move that led here (None for root)
    is_opponent_move: bool = False
    
    # Tracking
    path_probability: float = 1.0  # Cumulative opponent probability
    local_ease: Optional[float] = None  # Ease score at this position
    eval_cp: Optional[float] = None  # Stockfish eval in centipawns
    
    # Tree structure
    children: List['TreeNode'] = field(default_factory=list)
    parent: Optional['TreeNode'] = None


@dataclass 
class Line:
    """A flattened line with its metrics."""
    moves: List[str]
    survival_score: float  # Product of opponent Ease scores
    path_probability: float
    final_eval: Optional[float]
    
    @property
    def pressure_score(self) -> float:
        """Lower survival = higher pressure = trickier."""
        return 1.0 - self.survival_score


class EaseCalculator:
    """
    Calculates Ease scores using move probabilities and engine eval.
    
    Ease = 1 - (weighted_regret)^ALPHA
    where weighted_regret = Σ(prob^BETA × normalized_regret)
    """
    
    def __init__(
        self,
        probability_provider: ProbabilityProvider,
        engine: UCIEngine,
        engine_depth: int = 12
    ):
        self.prob_provider = probability_provider
        self.engine = engine
        self.engine_depth = engine_depth
    
    def calculate_ease(
        self,
        board: chess.Board,
        player_elo: int = 2000
    ) -> float:
        """
        Calculate Ease score for a position.
        
        Returns:
            Ease between 0.0 (treacherous) and 1.0 (easy)
        """
        pov_color = board.turn
        
        # Get human move probabilities
        move_probs = self.prob_provider.get_move_probabilities(
            board, player_elo=player_elo, opponent_elo=player_elo, min_probability=0.01
        )
        
        if not move_probs:
            return 1.0
        
        # Take top moves covering ~90% probability
        sorted_moves = sorted(move_probs.items(), key=lambda x: x[1], reverse=True)
        candidates = []
        cumulative = 0.0
        for move_san, prob in sorted_moves:
            candidates.append((move_san, prob))
            cumulative += prob
            if cumulative > 0.90:
                break
        
        if not candidates:
            return 1.0
        
        # Evaluate each candidate
        evals: Dict[str, float] = {}
        for move_san, _ in candidates:
            try:
                child = board.copy()
                child.push_san(move_san)
                ev = self.engine.evaluate(child, depth=self.engine_depth, pov_color=pov_color)
                if ev is not None:
                    evals[move_san] = ev
            except:
                continue
        
        if not evals:
            return 1.0
        
        best_eval = max(evals.values())
        
        # Calculate weighted regret
        weighted_regret = 0.0
        for move_san, prob in candidates:
            if move_san not in evals:
                continue
            regret_cp = max(0.0, best_eval - evals[move_san])
            regret_norm = min(1.0, regret_cp / 200.0)  # Normalize to 0-1
            weighted_regret += (prob ** BETA) * regret_norm
        
        raw_ease = 1.0 - math.pow(min(1.0, weighted_regret / 2.0), ALPHA)
        return max(0.0, min(1.0, raw_ease))


class PressureTreeBuilder:
    """
    Builds and analyzes a repertoire tree for sustained pressure.
    """
    
    def __init__(
        self,
        my_color: chess.Color,
        probability_provider: ProbabilityProvider,
        engine: UCIEngine,
        opponent_elo: int = 2000,
        engine_depth: int = 12
    ):
        self.my_color = my_color
        self.prob_provider = probability_provider
        self.engine = engine
        self.opponent_elo = opponent_elo
        
        self.ease_calc = EaseCalculator(probability_provider, engine, engine_depth)
        self.root: Optional[TreeNode] = None
    
    def build(
        self,
        start_board: chess.Board,
        line_depth: int = 10,
        min_eval_cp: float = 0.0,
        max_eval_cp: float = 200.0,
        probability_threshold: float = 0.01,
        my_move_count: int = 3,
        my_move_tolerance_cp: float = 30.0,
        initial_moves: Optional[List[str]] = None
    ) -> TreeNode:
        """
        Build the exploration tree.
        
        Args:
            start_board: Starting position
            line_depth: Max depth in ply
            min_eval_cp: Don't go below this eval (from our perspective)
            max_eval_cp: Don't explore above this (position is "won")
            probability_threshold: Prune when cumulative opponent prob < this
            my_move_count: Pick this many moves for our turns
            my_move_tolerance_cp: Our moves must be within this of best
            initial_moves: Moves already played
        """
        self.root = TreeNode(
            fen=start_board.fen(),
            path_probability=1.0
        )
        
        self._build_recursive(
            node=self.root,
            board=start_board,
            depth=0,
            max_depth=line_depth,
            min_eval=min_eval_cp,
            max_eval=max_eval_cp,
            prob_threshold=probability_threshold,
            my_move_count=my_move_count,
            my_move_tolerance=my_move_tolerance_cp
        )
        
        return self.root
    
    def _build_recursive(
        self,
        node: TreeNode,
        board: chess.Board,
        depth: int,
        max_depth: int,
        min_eval: float,
        max_eval: float,
        prob_threshold: float,
        my_move_count: int,
        my_move_tolerance: float
    ):
        """Recursively build the tree."""
        # Depth limit
        if depth >= max_depth:
            return
        
        # Probability cutoff
        if node.path_probability < prob_threshold:
            return
        
        if board.is_game_over():
            return
        
        is_my_turn = board.turn == self.my_color
        
        if is_my_turn:
            self._expand_my_moves(
                node, board, depth, max_depth, min_eval, max_eval,
                prob_threshold, my_move_count, my_move_tolerance
            )
        else:
            self._expand_opponent_moves(
                node, board, depth, max_depth, min_eval, max_eval,
                prob_threshold, my_move_count, my_move_tolerance
            )
    
    def _expand_my_moves(
        self,
        node: TreeNode,
        board: chess.Board,
        depth: int,
        max_depth: int,
        min_eval: float,
        max_eval: float,
        prob_threshold: float,
        my_move_count: int,
        my_move_tolerance: float
    ):
        """Expand our moves - pick a few good ones weighted by ease + eval."""
        # Get move probabilities (for ease weighting)
        move_probs = self.prob_provider.get_move_probabilities(
            board, player_elo=self.opponent_elo, opponent_elo=self.opponent_elo, min_probability=0.01
        )
        
        if not move_probs:
            # Fallback: just use legal moves
            move_probs = {board.san(m): 1.0 / len(list(board.legal_moves)) 
                         for m in board.legal_moves}
        
        # Evaluate all candidate moves
        candidates: List[Tuple[str, float, float]] = []  # (move, eval, prob)
        
        for move_san, prob in move_probs.items():
            try:
                child = board.copy()
                child.push_san(move_san)
                ev = self.engine.evaluate(child, depth=12, pov_color=self.my_color)
                if ev is not None:
                    candidates.append((move_san, ev, prob))
            except:
                continue
        
        if not candidates:
            return
        
        # Find best eval
        best_eval = max(ev for _, ev, _ in candidates)
        
        # Filter: within tolerance of best, within min/max bounds
        valid = []
        for move_san, ev, prob in candidates:
            # Must be within tolerance of best
            if ev < best_eval - my_move_tolerance:
                continue
            # Must be above min_eval
            if ev < min_eval:
                continue
            # Skip if position is "won" (above max_eval)
            if ev > max_eval:
                continue
            valid.append((move_san, ev, prob))
        
        if not valid:
            # If all moves are above max_eval, position is won - stop exploring
            # If all below min_eval, we're losing - stop exploring
            return
        
        # Weight by (normalized_eval + ease_proxy) and pick randomly
        # Use probability as ease proxy here
        weights = []
        for move_san, ev, prob in valid:
            # Normalize eval to 0-1 range (assuming -200 to +200 cp range)
            ev_norm = (ev + 200) / 400
            weight = ev_norm * 0.5 + prob * 0.5
            weights.append(weight)
        
        # Normalize weights
        total_weight = sum(weights)
        if total_weight == 0:
            return
        weights = [w / total_weight for w in weights]
        
        # Sample up to my_move_count moves (weighted random without replacement)
        selected = []
        remaining = list(zip(valid, weights))
        
        for _ in range(min(my_move_count, len(remaining))):
            if not remaining:
                break
            moves_only = [m for m, _ in remaining]
            weights_only = [w for _, w in remaining]
            
            # Normalize weights for this round
            total = sum(weights_only)
            if total == 0:
                break
            probs = [w / total for w in weights_only]
            
            idx = random.choices(range(len(remaining)), weights=probs, k=1)[0]
            selected.append(remaining[idx][0])
            remaining.pop(idx)
        
        # Create child nodes for selected moves
        for move_san, ev, prob in selected:
            child_board = board.copy()
            child_board.push_san(move_san)
            
            child_node = TreeNode(
                fen=child_board.fen(),
                move_san=move_san,
                is_opponent_move=False,
                path_probability=node.path_probability,  # Unchanged for our moves
                local_ease=None,  # We don't track ease for our moves
                eval_cp=ev,
                parent=node
            )
            node.children.append(child_node)
            
            # Recurse
            self._build_recursive(
                child_node, child_board, depth + 1, max_depth,
                min_eval, max_eval, prob_threshold, my_move_count, my_move_tolerance
            )
    
    def _expand_opponent_moves(
        self,
        node: TreeNode,
        board: chess.Board,
        depth: int,
        max_depth: int,
        min_eval: float,
        max_eval: float,
        prob_threshold: float,
        my_move_count: int,
        my_move_tolerance: float
    ):
        """Expand opponent moves - purely by probability from database."""
        # Calculate ease at this position (opponent is about to move)
        local_ease = self.ease_calc.calculate_ease(board, player_elo=self.opponent_elo)
        node.local_ease = local_ease
        
        # Get move probabilities from Lichess
        move_probs = self.prob_provider.get_move_probabilities(
            board, player_elo=self.opponent_elo, opponent_elo=self.opponent_elo, min_probability=0.01
        )
        
        if not move_probs:
            return
        
        # Sort by probability
        sorted_moves = sorted(move_probs.items(), key=lambda x: x[1], reverse=True)
        
        # Explore moves where cumulative path probability stays above threshold
        for move_san, prob in sorted_moves:
            new_path_prob = node.path_probability * prob
            
            if new_path_prob < prob_threshold:
                continue  # Prune - too unlikely
            
            try:
                child_board = board.copy()
                child_board.push_san(move_san)
                
                # Get eval of resulting position
                ev = self.engine.evaluate(child_board, depth=12, pov_color=self.my_color)
                
                child_node = TreeNode(
                    fen=child_board.fen(),
                    move_san=move_san,
                    is_opponent_move=True,
                    path_probability=new_path_prob,
                    local_ease=local_ease,  # Ease of position they faced
                    eval_cp=ev,
                    parent=node
                )
                node.children.append(child_node)
                
                print(f"  {depth}: {move_san} (prob={new_path_prob:.2%}, ease={local_ease:.2f})")
                
                # Recurse
                self._build_recursive(
                    child_node, child_board, depth + 1, max_depth,
                    min_eval, max_eval, prob_threshold, my_move_count, my_move_tolerance
                )
            except:
                continue
    
    def flatten_to_lines(self) -> List[Line]:
        """
        Flatten the tree into Line objects with survival scores.
        """
        lines = []
        self._collect_lines(self.root, [], 1.0, lines)
        return lines
    
    def _collect_lines(
        self,
        node: TreeNode,
        current_moves: List[str],
        cumulative_ease: float,
        lines: List[Line]
    ):
        """Recursively collect lines from the tree."""
        # Build move list
        moves = current_moves.copy()
        if node.move_san:
            moves.append(node.move_san)
        
        # Update cumulative ease (only for opponent moves)
        ease = cumulative_ease
        if node.is_opponent_move and node.local_ease is not None:
            ease *= node.local_ease
        
        if not node.children:
            # Leaf node - save line
            if moves:  # Don't save empty lines
                lines.append(Line(
                    moves=moves,
                    survival_score=ease,
                    path_probability=node.path_probability,
                    final_eval=node.eval_cp
                ))
        else:
            # Recurse into children
            for child in node.children:
                self._collect_lines(child, moves, ease, lines)
    
    def get_sorted_lines(self) -> List[Line]:
        """Get all lines sorted by pressure (lowest survival first)."""
        lines = self.flatten_to_lines()
        lines.sort(key=lambda l: l.survival_score)
        return lines
    
    def print_results(self, max_lines: int = None):
        """Print sorted lines."""
        lines = self.get_sorted_lines()
        
        print("\n" + "=" * 70)
        print("SUSTAINED PRESSURE ANALYSIS")
        print("=" * 70)
        print(f"Total lines found: {len(lines)}")
        
        display_lines = lines if max_lines is None else lines[:max_lines]
        
        print(f"\nAll {len(display_lines)} lines sorted by survival (lowest = trickiest):")
        print("-" * 70)
        print(f"{'Survival':<10} {'Prob':<8} {'Eval':<8} Line")
        print("-" * 70)
        
        for line in display_lines:
            eval_str = f"{line.final_eval:+.0f}" if line.final_eval is not None else "?"
            moves_str = " ".join(line.moves)
            print(f"{line.survival_score:<10.3f} {line.path_probability:<8.2%} {eval_str:<8} {moves_str}")
        
        print("=" * 70)


def run_pressure_analysis(
    board: chess.Board,
    my_color: chess.Color,
    probability_provider: ProbabilityProvider,
    engine: UCIEngine,
    line_depth: int = 10,
    min_eval_cp: float = 0.0,
    max_eval_cp: float = 200.0,
    probability_threshold: float = 0.01,
    opponent_elo: int = 2000,
    initial_moves: Optional[List[str]] = None,
    max_lines: int = 20
) -> List[Line]:
    """
    Main entry point for pressure analysis.
    
    Returns sorted list of lines (lowest survival = trickiest first).
    """
    builder = PressureTreeBuilder(
        my_color=my_color,
        probability_provider=probability_provider,
        engine=engine,
        opponent_elo=opponent_elo,
        engine_depth=12
    )
    
    print(f"\n[BUILDING] Pressure analysis tree...")
    print(f"  Depth: {line_depth} ply")
    print(f"  Eval bounds: [{min_eval_cp:+.0f}, {max_eval_cp:+.0f}] cp")
    print(f"  Probability threshold: {probability_threshold:.1%}")
    print(f"  Opponent ELO: {opponent_elo}")
    
    builder.build(
        start_board=board,
        line_depth=line_depth,
        min_eval_cp=min_eval_cp,
        max_eval_cp=max_eval_cp,
        probability_threshold=probability_threshold,
        initial_moves=initial_moves
    )
    
    builder.print_results(max_lines=max_lines)
    
    return builder.get_sorted_lines()
