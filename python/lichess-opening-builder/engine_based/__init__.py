"""
Engine-Based Opening Repertoire Builder

This module finds "tricky" opening lines where opponents are likely to make mistakes
by combining Stockfish evaluations with Maia2's human move probabilities.

Clean Architecture:
1. Build tree with Maia2 probabilities
2. Evaluate leaf nodes with Stockfish
3. Propagate expected values back up
"""

from .uci_engine import UCIEngine
from .maia2_wrapper import Maia2
from .tree_search import (
    TreeNode,
    build_tree,
    evaluate_tree,
    find_best_lines,
    analyze_opening,
    print_tree_stats
)

__all__ = [
    'UCIEngine',
    'Maia2',
    'TreeNode',
    'build_tree',
    'evaluate_tree',
    'find_best_lines',
    'analyze_opening',
    'print_tree_stats'
]
