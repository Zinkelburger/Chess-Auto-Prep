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
    min_probability: float = 0.1,
    top_n_my_moves: int = 3,
    top_n_opponent_moves: int = 5,
    player_elo: int = 1500,
    opponent_elo: int = 1500,
    prune_bad_moves_cp: Optional[float] = 100.0,
    prune_winning_cp: Optional[float] = 100.0,
    prune_opponent_blunders_cp: Optional[float] = 200.0
) -> Generator[Tuple[TreeNode, Optional[TreeNode]], None, TreeNode]:
    """
    Build a tree of moves using Maia2 probabilities with pruning.
    Yields (root, leaf) tuples as each leaf is discovered (for incremental processing).

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
        top_n_my_moves: Max moves to explore on your turn
        top_n_opponent_moves: Max opponent moves to explore
        player_elo: Your ELO rating
        opponent_elo: Opponent's ELO rating
        prune_bad_moves_cp: Max eval drop from ROOT allowed for your moves (None = no pruning)
        prune_winning_cp: Stop exploring if improved by >N cp from ROOT (None = no pruning)
        prune_opponent_blunders_cp: Stop exploring after opponent loses >N cp (None = no pruning)

    Yields:
        (root, leaf_node) tuples as leaves are discovered during DFS

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

    # Evaluate root position once for relative pruning
    root_eval = stockfish_engine.evaluate(start_board, depth=20)
    if root_eval is None:
        root_eval = 0.0
    print(f"  Root position eval: {root_eval:+.1f} cp")

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
            # Hit max depth - this is a leaf, evaluate it immediately
            eval_cp = stockfish_engine.evaluate(node.board, depth=20)
            if eval_cp is None:
                eval_cp = 0.0
            node.eval_cp = eval_cp
            node.expected_value = eval_cp
            yield node  # Yield the leaf for immediate processing
            return

        # Prune if position is already winning enough relative to ROOT
        if prune_winning_cp is not None:
            current_eval = stockfish_engine.evaluate(node.board, depth=20)
            if current_eval is not None:
                # Check if we've improved enough from root position
                if my_color == chess.WHITE:
                    improvement = current_eval - root_eval
                else:
                    improvement = root_eval - current_eval

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
            # No legal moves above threshold - this becomes a leaf
            eval_cp = stockfish_engine.evaluate(node.board, depth=20)
            if eval_cp is None:
                eval_cp = 0.0
            node.eval_cp = eval_cp
            node.expected_value = eval_cp
            yield node
            return

        # Sort by probability and take top N
        sorted_moves = sorted(move_probs.items(), key=lambda x: x[1], reverse=True)
        top_moves = sorted_moves[:top_n]

        # Prune objectively bad moves (only for MY moves)
        if is_my_turn and prune_bad_moves_cp is not None:
            # Evaluate each candidate move and filter based on ROOT position
            filtered_moves = []
            for move_san, prob in top_moves:
                child_board = node.board.copy()
                child_board.push_san(move_san)
                child_eval = stockfish_engine.evaluate(child_board, depth=20)

                if child_eval is None:
                    # Can't evaluate, keep it to be safe
                    filtered_moves.append((move_san, prob))
                    continue

                # Calculate eval change from ROOT position, from my perspective
                if my_color == chess.WHITE:
                    eval_delta = child_eval - root_eval
                else:
                    eval_delta = root_eval - child_eval

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
                child_eval = stockfish_engine.evaluate(child_board, depth=20)
                if child_eval is not None:
                    # Calculate how much the opponent's move changed the eval (from my perspective)
                    parent_eval = stockfish_engine.evaluate(node.board, depth=20)
                    if parent_eval is not None:
                        # Improvement from my perspective
                        if my_color == chess.WHITE:
                            eval_swing = child_eval - parent_eval
                        else:
                            eval_swing = parent_eval - child_eval

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
