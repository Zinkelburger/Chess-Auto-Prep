"""
Tree-based opening analysis using Maia2 and Stockfish.

Clean architecture:
1. Build tree using Maia2 move probabilities
2. Evaluate leaf nodes with Stockfish
3. Propagate expected values back up
"""

import chess
from typing import List, Optional, Tuple
from dataclasses import dataclass


@dataclass
class TreeNode:
    """
    A node in the opening tree.
    """
    board: chess.Board
    move: Optional[str]  # SAN move that led to this position (None for root)
    parent: Optional['TreeNode']
    children: List['TreeNode']
    depth: int

    # Probabilities (from Maia2)
    move_probability: float  # Probability of THIS move being played

    # Evaluations (from Stockfish)
    eval_cp: Optional[float] = None  # Centipawn evaluation (white's perspective)
    expected_value: Optional[float] = None  # Expected value considering children

    def __post_init__(self):
        self.children = []

    def add_child(self, child: 'TreeNode'):
        """Add a child node."""
        self.children.append(child)

    def is_leaf(self) -> bool:
        """Check if this is a leaf node."""
        return len(self.children) == 0

    def get_line(self) -> List[str]:
        """Get the move sequence from root to this node."""
        line = []
        node = self
        while node.parent is not None:
            if node.move:
                line.append(node.move)
            node = node.parent
        return list(reversed(line))

    def is_my_turn(self, my_color: chess.Color) -> bool:
        """Check if it's my turn at this node."""
        return self.board.turn == my_color


def build_tree(
    start_board: chess.Board,
    maia2_model,
    stockfish_engine,
    max_depth: int,
    my_color: chess.Color,
    min_probability: float = 0.1,
    top_n_my_moves: int = 3,
    top_n_opponent_moves: int = 5,
    player_elo: int = 1500,
    opponent_elo: int = 1500,
    prune_bad_moves_cp: Optional[float] = 100.0,
    prune_winning_cp: Optional[float] = 200.0
) -> TreeNode:
    """
    Build a tree of moves using Maia2 probabilities with pruning.

    Args:
        start_board: Starting position
        maia2_model: Maia2 model instance
        stockfish_engine: Stockfish for evaluating and pruning moves
        max_depth: Maximum depth in ply (half-moves)
        my_color: Your color
        min_probability: Minimum probability to include a move
        top_n_my_moves: Max moves to explore on your turn
        top_n_opponent_moves: Max opponent moves to explore
        player_elo: Your ELO rating
        opponent_elo: Opponent's ELO rating
        prune_bad_moves_cp: Max eval drop allowed for your moves (None = no pruning)
        prune_winning_cp: Stop exploring if eval exceeds this (None = no pruning)

    Returns:
        Root node of the tree
    """
    root = TreeNode(
        board=start_board.copy(),
        move=None,
        parent=None,
        children=[],
        depth=0,
        move_probability=1.0
    )

    def _expand_node(node: TreeNode):
        """Recursively expand a node."""
        if node.depth >= max_depth:
            return

        # Prune if position is already winning enough
        if prune_winning_cp is not None:
            current_eval = stockfish_engine.evaluate(node.board, depth=15)
            if current_eval is not None:
                # Check if position is winning from my perspective
                if my_color == chess.WHITE:
                    is_winning = current_eval >= prune_winning_cp
                else:
                    is_winning = current_eval <= -prune_winning_cp

                if is_winning:
                    print(f"    [PRUNED] Already winning at depth {node.depth}: eval = {current_eval:+.0f} cp")
                    return

        is_my_turn = node.is_my_turn(my_color)

        # Get move probabilities from Maia2
        # For "my" moves, use player_elo; for opponent, use opponent_elo
        if is_my_turn:
            current_elo = player_elo
            opposing_elo = opponent_elo
            top_n = top_n_my_moves
        else:
            current_elo = opponent_elo
            opposing_elo = player_elo
            top_n = top_n_opponent_moves

        move_probs = maia2_model.get_move_probabilities(
            node.board,
            player_elo=current_elo,
            opponent_elo=opposing_elo,
            min_probability=min_probability
        )

        if not move_probs:
            # No legal moves above threshold
            return

        # Sort by probability and take top N
        sorted_moves = sorted(move_probs.items(), key=lambda x: x[1], reverse=True)
        top_moves = sorted_moves[:top_n]

        # Prune objectively bad moves (only for MY moves)
        if is_my_turn and prune_bad_moves_cp is not None:
            # Evaluate parent position (reuse if we already evaluated for winning check)
            if prune_winning_cp is not None and node.depth > 0:
                # We might have already evaluated this position
                parent_eval = stockfish_engine.evaluate(node.board, depth=15)
            else:
                parent_eval = stockfish_engine.evaluate(node.board, depth=15)

            if parent_eval is None:
                parent_eval = 0.0

            # Evaluate each candidate move and filter
            filtered_moves = []
            for move_san, prob in top_moves:
                child_board = node.board.copy()
                child_board.push_san(move_san)
                child_eval = stockfish_engine.evaluate(child_board, depth=15)

                if child_eval is None:
                    # Can't evaluate, keep it to be safe
                    filtered_moves.append((move_san, prob))
                    continue

                # Calculate eval change from my perspective
                if my_color == chess.WHITE:
                    eval_delta = child_eval - parent_eval
                else:
                    eval_delta = parent_eval - child_eval

                # If move drops eval by more than threshold, prune it
                if eval_delta >= -prune_bad_moves_cp:
                    filtered_moves.append((move_san, prob))
                else:
                    print(f"    [PRUNED] {move_san}: drops eval by {-eval_delta:.0f} cp")

            top_moves = filtered_moves

        # Create child nodes
        for move_san, prob in top_moves:
            child_board = node.board.copy()
            child_board.push_san(move_san)

            child_node = TreeNode(
                board=child_board,
                move=move_san,
                parent=node,
                children=[],
                depth=node.depth + 1,
                move_probability=prob
            )

            node.add_child(child_node)

            # Recursively expand child
            _expand_node(child_node)

    # Start expansion from root
    _expand_node(root)

    return root


def evaluate_tree(root: TreeNode, stockfish_engine, my_color: chess.Color):  # noqa: ARG001
    """
    Evaluate the tree by:
    1. Evaluating leaf nodes with Stockfish
    2. Propagating expected values back up

    Args:
        root: Root node of the tree
        stockfish_engine: Stockfish engine instance
        my_color: Your color (reserved for future use)
    """

    def _evaluate_node(node: TreeNode) -> float:
        """
        Recursively evaluate a node and return its expected value.

        Returns:
            Expected value in centipawns (from white's perspective)
        """
        if node.is_leaf():
            # Leaf node: evaluate with Stockfish
            eval_cp = stockfish_engine.evaluate(node.board, depth=20)
            if eval_cp is None:
                eval_cp = 0.0  # Fallback if evaluation fails
            node.eval_cp = eval_cp
            node.expected_value = eval_cp
            return eval_cp

        else:
            # Internal node: calculate expected value from children
            # EV = sum(child_ev * child_probability) / sum(child_probability)

            # First, evaluate all children recursively
            child_values = []
            total_prob = 0.0

            for child in node.children:
                child_ev = _evaluate_node(child)
                child_values.append((child_ev, child.move_probability))
                total_prob += child.move_probability

            # Calculate weighted average
            if total_prob > 0:
                expected_val = sum(ev * prob for ev, prob in child_values) / total_prob
            else:
                expected_val = 0.0

            node.expected_value = expected_val
            return expected_val

    # Start evaluation from root
    _evaluate_node(root)


def find_best_lines(
    root: TreeNode,
    my_color: chess.Color,
    num_lines: int = 5,
    criterion: str = "trickiness"
) -> List[Tuple[List[str], float, float, float]]:
    """
    Find the best lines from the tree.

    Args:
        root: Root node of the tree
        my_color: Your color
        num_lines: Number of lines to return
        criterion: How to rank lines - "trickiness", "eval", or "expected_value"

    Returns:
        List of (moves, eval, expected_value, trickiness) tuples
    """
    # Collect all leaf nodes
    leaves = []

    def _collect_leaves(node: TreeNode):
        if node.is_leaf():
            leaves.append(node)
        else:
            for child in node.children:
                _collect_leaves(child)

    _collect_leaves(root)

    # Calculate trickiness for each leaf
    # Trickiness = how much better you are after opponent's likely mistakes
    results = []
    for leaf in leaves:
        line = leaf.get_line()
        eval_cp = leaf.eval_cp if leaf.eval_cp is not None else 0.0
        expected_val = leaf.expected_value if leaf.expected_value is not None else 0.0

        # Trickiness: difference between eval and expected value
        # From your perspective (positive = good for you)
        if my_color == chess.WHITE:
            trickiness = eval_cp - expected_val
        else:
            trickiness = expected_val - eval_cp

        results.append((line, eval_cp, expected_val, trickiness))

    # Sort by criterion
    if criterion == "trickiness":
        results.sort(key=lambda x: x[3], reverse=True)
    elif criterion == "eval":
        if my_color == chess.WHITE:
            results.sort(key=lambda x: x[1], reverse=True)
        else:
            results.sort(key=lambda x: x[1], reverse=False)
    elif criterion == "expected_value":
        if my_color == chess.WHITE:
            results.sort(key=lambda x: x[2], reverse=True)
        else:
            results.sort(key=lambda x: x[2], reverse=False)

    return results[:num_lines]


def analyze_opening(
    start_board: chess.Board,
    maia2_model,
    stockfish_engine,
    my_color: chess.Color,
    max_depth: int = 20,
    num_lines: int = 5,
    min_probability: float = 0.1,
    top_n_my_moves: int = 3,
    top_n_opponent_moves: int = 5,
    player_elo: int = 1500,
    opponent_elo: int = 1500,
    prune_bad_moves_cp: Optional[float] = 100.0,
    prune_winning_cp: Optional[float] = 200.0,
    criterion: str = "trickiness"
) -> Tuple[TreeNode, List[Tuple[List[str], float, float, float]]]:
    """
    Complete opening analysis pipeline.

    1. Build tree with Maia2 probabilities (with pruning)
    2. Evaluate with Stockfish
    3. Find best lines

    Args:
        start_board: Starting position
        maia2_model: Maia2 model instance
        stockfish_engine: Stockfish engine
        my_color: Your color
        max_depth: Maximum depth in ply
        num_lines: Number of best lines to return
        min_probability: Minimum probability threshold
        top_n_my_moves: Number of your moves to explore
        top_n_opponent_moves: Number of opponent moves to explore
        player_elo: Your ELO rating
        opponent_elo: Opponent's ELO rating
        prune_bad_moves_cp: Max eval drop for your moves (None = no pruning)
        prune_winning_cp: Stop exploring if eval exceeds this (None = no pruning)
        criterion: Ranking criterion ("trickiness", "eval", "expected_value")

    Returns:
        (tree_root, best_lines) tuple
    """
    print("Building tree with Maia2 probabilities...")
    root = build_tree(
        start_board=start_board,
        maia2_model=maia2_model,
        stockfish_engine=stockfish_engine,
        max_depth=max_depth,
        my_color=my_color,
        min_probability=min_probability,
        top_n_my_moves=top_n_my_moves,
        top_n_opponent_moves=top_n_opponent_moves,
        player_elo=player_elo,
        opponent_elo=opponent_elo,
        prune_bad_moves_cp=prune_bad_moves_cp,
        prune_winning_cp=prune_winning_cp
    )

    print("Evaluating tree with Stockfish...")
    evaluate_tree(root, stockfish_engine, my_color)

    print("Finding best lines...")
    best_lines = find_best_lines(root, my_color, num_lines, criterion)

    return root, best_lines


def print_tree_stats(root: TreeNode):
    """Print statistics about the tree."""
    node_count = 0
    leaf_count = 0
    max_depth = 0

    def _traverse(node: TreeNode):
        nonlocal node_count, leaf_count, max_depth
        node_count += 1
        max_depth = max(max_depth, node.depth)

        if node.is_leaf():
            leaf_count += 1
        else:
            for child in node.children:
                _traverse(child)

    _traverse(root)

    print(f"Tree Statistics:")
    print(f"  Total nodes: {node_count}")
    print(f"  Leaf nodes: {leaf_count}")
    print(f"  Max depth: {max_depth} ply")
