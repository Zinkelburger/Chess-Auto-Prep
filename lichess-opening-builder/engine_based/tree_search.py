"""
Tree-based opening analysis using Maia2 and Stockfish.

Clean architecture:
1. Build tree using Maia2 move probabilities
2. Evaluate leaf nodes with Stockfish
3. Propagate expected values back up
"""

import chess
from typing import List, Optional, Tuple, Generator
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

    # Evaluations (from Stockfish) - always from the player's perspective
    eval_cp: Optional[float] = None  # Centipawn evaluation (player's perspective)
    expected_value: Optional[float] = None  # Expected value (player: max of children, opponent: probability-weighted)

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

    def get_line_probability(self) -> float:
        """
        Get the cumulative probability of reaching this node.
        Product of all move probabilities from root to this node.
        """
        prob = 1.0
        node = self
        while node.parent is not None:
            prob *= node.move_probability
            node = node.parent
        return prob

    def is_my_turn(self, my_color: chess.Color) -> bool:
        """Check if it's my turn at this node."""
        return self.board.turn == my_color


def build_tree_incremental(
    start_board: chess.Board,
    maia2_model,
    stockfish_engine,
    max_depth: int,
    my_color: chess.Color,
    min_probability: float = 0.10,
    top_n_my_moves: Optional[int] = 3,
    top_n_opponent_moves: Optional[int] = 5,
    min_probability_opponent: Optional[float] = None,
    player_elo: int = 1500,
    opponent_elo: int = 1500,
    prune_bad_moves_cp: Optional[float] = 100.0,
    prune_winning_cp: Optional[float] = 100.0,
    prune_opponent_blunders_cp: Optional[float] = 200.0
) -> Generator[Tuple[TreeNode, Optional[TreeNode]], None, TreeNode]:
    """
    Build a tree of moves using Maia2 probabilities with pruning.
    Yields leaf nodes as they're discovered during DFS.

    All pruning is done RELATIVE to the root position's evaluation:
    - prune_bad_moves_cp: Prune your moves that worsen position by >N cp from root
    - prune_winning_cp: Stop exploring if position improves by >N cp from root
    - prune_opponent_blunders_cp: Stop exploring after opponent blunders by >N cp

    Args:
        start_board: Starting position
        maia2_model: Maia2 model instance
        stockfish_engine: Stockfish for evaluating and pruning moves
        max_depth: Maximum depth in ply (half-moves)
        my_color: Your color
        min_probability: Minimum probability to include a move
        top_n_my_moves: Max moves to explore on your turn (None = use min_probability only)
        top_n_opponent_moves: Max opponent moves (None = use min_probability_opponent)
        min_probability_opponent: Min probability for opponent moves (overrides min_probability if set)
        player_elo: Your ELO rating
        opponent_elo: Opponent's ELO rating
        prune_bad_moves_cp: Max eval drop from ROOT allowed for your moves (None = no pruning)
        prune_winning_cp: Stop exploring if improved by >N cp from ROOT (None = no pruning)
        prune_opponent_blunders_cp: Stop exploring after opponent loses >N cp (None = no pruning)

    Yields:
        Leaf nodes as they're discovered during DFS

    Returns:
        Root node of the completed tree
    """
    root = TreeNode(
        board=start_board.copy(),
        move=None,
        parent=None,
        children=[],
        depth=0,
        move_probability=1.0
    )

    # Evaluate root position once for relative pruning (from player's POV)
    root_eval = stockfish_engine.evaluate(start_board, depth=20, pov_color=my_color)
    if root_eval is None:
        root_eval = 0.0
    print(f"  Root position eval: {root_eval:+.1f} cp (from your perspective)")

    # Progress tracking
    nodes_explored = [0]
    last_print = [0]

    def _expand_node(node: TreeNode):
        """Recursively expand a node. Yields leaf nodes as they're found."""
        # Progress indicator
        nodes_explored[0] += 1
        if nodes_explored[0] - last_print[0] >= 100:
            print(f"  Explored {nodes_explored[0]} nodes (depth {node.depth})...", end='\r', flush=True)
            last_print[0] = nodes_explored[0]

        if node.depth >= max_depth:
            # Hit max depth - this is a leaf, evaluate it immediately (from player's POV)
            eval_cp = stockfish_engine.evaluate(node.board, depth=20, pov_color=my_color)
            if eval_cp is None:
                eval_cp = 0.0
            node.eval_cp = eval_cp
            node.expected_value = eval_cp
            yield node  # Yield the leaf for immediate processing
            return

        # Prune if position is already winning enough relative to ROOT
        if prune_winning_cp is not None:
            current_eval = stockfish_engine.evaluate(node.board, depth=20, pov_color=my_color)
            if current_eval is not None:
                # Check if we've improved enough from root position (from player's POV)
                improvement = current_eval - root_eval

                if improvement >= prune_winning_cp:
                    print(f"    [PRUNED] Improved by {improvement:+.0f} cp from root at depth {node.depth}")
                    # This becomes a leaf due to pruning, evaluate and yield
                    node.eval_cp = current_eval
                    node.expected_value = current_eval
                    yield node
                    return

        is_my_turn = node.is_my_turn(my_color)

        # Get move probabilities from Maia2
        # For "my" moves, use player_elo; for opponent, use opponent_elo
        if is_my_turn:
            current_elo = player_elo
            opposing_elo = opponent_elo
            top_n = top_n_my_moves
            prob_threshold = min_probability
        else:
            current_elo = opponent_elo
            opposing_elo = player_elo
            top_n = top_n_opponent_moves
            # Use separate threshold for opponent if specified
            prob_threshold = min_probability_opponent if min_probability_opponent is not None else min_probability

        move_probs = maia2_model.get_move_probabilities(
            node.board,
            player_elo=current_elo,
            opponent_elo=opposing_elo,
            min_probability=prob_threshold
        )

        if not move_probs:
            # No legal moves above threshold - this becomes a leaf
            eval_cp = stockfish_engine.evaluate(node.board, depth=20, pov_color=my_color)
            if eval_cp is None:
                eval_cp = 0.0
            node.eval_cp = eval_cp
            node.expected_value = eval_cp
            yield node
            return

        # Sort by probability
        sorted_moves = sorted(move_probs.items(), key=lambda x: x[1], reverse=True)

        # Apply top-N limit if specified, otherwise use all moves above threshold
        if top_n is not None:
            top_moves = sorted_moves[:top_n]
        else:
            top_moves = sorted_moves

        # Prune objectively bad moves (only for MY moves)
        if is_my_turn and prune_bad_moves_cp is not None:
            # Evaluate each candidate move and filter based on ROOT position
            filtered_moves = []
            for move_san, prob in top_moves:
                child_board = node.board.copy()
                child_board.push_san(move_san)
                child_eval = stockfish_engine.evaluate(child_board, depth=20, pov_color=my_color)

                if child_eval is None:
                    # Can't evaluate, keep it to be safe
                    filtered_moves.append((move_san, prob))
                    continue

                # Calculate eval change from ROOT position (from player's POV)
                eval_delta = child_eval - root_eval

                # If move drops eval by more than threshold relative to ROOT, prune it
                if eval_delta >= -prune_bad_moves_cp:
                    filtered_moves.append((move_san, prob))
                else:
                    print(f"    [PRUNED] {move_san}: drops eval by {-eval_delta:.0f} cp from root")

            # Safety check: if all moves were pruned, keep at least the best one
            if not filtered_moves and top_moves:
                best_move = top_moves[0]  # Highest probability move
                print(f"    [WARNING] All moves pruned, keeping best move: {best_move[0]}")
                filtered_moves = [best_move]

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

            # Check if opponent just blundered (only for opponent moves)
            if not is_my_turn and prune_opponent_blunders_cp is not None:
                child_eval = stockfish_engine.evaluate(child_board, depth=20, pov_color=my_color)
                if child_eval is not None:
                    # Calculate how much the opponent's move changed the eval (from my perspective)
                    parent_eval = stockfish_engine.evaluate(node.board, depth=20, pov_color=my_color)
                    if parent_eval is not None:
                        # Improvement from my perspective (positive = good for me)
                        eval_swing = child_eval - parent_eval

                        # If opponent lost more than threshold, mark as done (don't expand further)
                        if eval_swing >= prune_opponent_blunders_cp:
                            print(f"    [OPPONENT BLUNDER] {move_san}: lost {eval_swing:.0f} cp - marking as done")
                            # This becomes a leaf due to opponent blunder
                            child_node.eval_cp = child_eval
                            child_node.expected_value = child_eval
                            yield child_node
                            continue  # Don't expand this child

            # Recursively expand child (yield from to propagate leaf yields up)
            yield from _expand_node(child_node)

    # Start expansion from root and yield leaves as found
    yield from _expand_node(root)

    # Final progress report
    print(f"  Explored {nodes_explored[0]} nodes total.{' ' * 30}")

    return root




def calculate_expected_values(root: TreeNode, my_color: chess.Color) -> None:
    """
    Calculate expected values for all nodes via post-order traversal.

    Expected value = Σ(probability × child_value) for ALL nodes.

    This models human play according to Maia2 probabilities, not optimal play.

    Args:
        root: Root node of the tree
        my_color: Player's color (unused, kept for compatibility)
    """
    def _propagate(node: TreeNode) -> float:
        """Calculate expected value recursively."""

        if node.is_leaf():
            if node.expected_value is None:
                node.expected_value = node.eval_cp if node.eval_cp is not None else 0.0
            return node.expected_value

        # Recursively compute children's expected values
        child_values = []
        for child in node.children:
            child_ev = _propagate(child)
            child_values.append((child, child_ev))

        # Always use probability-weighted average (models Maia2 human play)
        total_prob = sum(child.move_probability for child in node.children)
        if total_prob > 0:
            node.expected_value = sum(
                (child.move_probability / total_prob) * ev
                for child, ev in child_values
            )
        else:
            # Fallback if probabilities don't sum properly
            node.expected_value = sum(ev for _, ev in child_values) / len(child_values)

        return node.expected_value

    _propagate(root)


def find_best_lines(root: TreeNode, my_color: chess.Color, min_value: float = 0.0) -> List[Tuple[TreeNode, float]]:
    """
    Find all opponent nodes with good expected value, sorted by expected value.

    Args:
        root: Root of the tree
        my_color: Player's color
        min_value: Minimum expected value threshold (from your perspective)

    Returns:
        List of (node, expected_value) sorted by expected value descending
    """
    good_lines = []

    def _traverse(node: TreeNode):
        # Collect opponent nodes with sufficient expected value
        if not node.is_my_turn(my_color) and node.expected_value is not None:
            if node.expected_value >= min_value:
                good_lines.append((node, node.expected_value))

        for child in node.children:
            _traverse(child)

    _traverse(root)

    # Sort by expected value (descending = better for you)
    good_lines.sort(key=lambda x: x[1], reverse=True)
    return good_lines


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
