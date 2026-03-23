#!/usr/bin/env python3
"""
Dry-run comparison of MetaEase vs alternative repertoire-selection metrics.

Simulates a small opening tree with hand-crafted data inspired by real
positions, then compares:

  1. Current MetaEase   — α-blend of local opponentDifficulty + future
  2. Depth-weighted     — explicit depth discount on ease contributions
  3. Expected CPL       — expected centipawn loss by opponent per move
  4. EV-CPL hybrid      — expected total centipawn cost across the line

No actual Stockfish or Lichess calls — everything is synthetic so we
can see how the *maths* behave.
"""

import math
from dataclasses import dataclass, field
from typing import Optional

# ── Ease formula constants (matching the Dart/C code) ─────────────────────

EASE_ALPHA = 1.0 / 3.0
EASE_BETA = 1.5
Q_SIGMOID_K = 0.004


def score_to_q(cp: int) -> float:
    if abs(cp) > 9000:
        return 1.0 if cp > 0 else -1.0
    win_prob = 1.0 / (1.0 + math.exp(-Q_SIGMOID_K * cp))
    return 2.0 * win_prob - 1.0


def compute_ease(move_evals: list[tuple[float, int]]) -> float:
    """
    Compute ease for a position.

    move_evals: list of (probability, eval_cp_for_mover)
    Higher ease = harder to blunder (all popular moves are near-optimal).
    """
    if not move_evals:
        return 0.5

    best_cp = max(cp for _, cp in move_evals)
    q_max = score_to_q(best_cp)

    sum_weighted_regret = 0.0
    for prob, cp in move_evals:
        if prob < 0.01:
            continue
        q_val = score_to_q(cp)
        regret = max(0.0, q_max - q_val)
        sum_weighted_regret += (prob ** EASE_BETA) * regret

    ease = 1.0 - (sum_weighted_regret / 2.0) ** EASE_ALPHA
    return max(0.0, min(1.0, ease))


def expected_cpl(move_evals: list[tuple[float, int]]) -> float:
    """
    Expected centipawn loss by the mover at this position.

    = Σ prob_i × max(0, best_cp - cp_i)

    Pure, interpretable: "on average, how many centipawns does the mover
    lose relative to the best available move?"
    """
    if not move_evals:
        return 0.0
    best_cp = max(cp for _, cp in move_evals)
    return sum(prob * max(0, best_cp - cp) for prob, cp in move_evals)


# ── Tree node ─────────────────────────────────────────────────────────────

@dataclass
class Node:
    name: str
    is_our_move: bool       # True = we choose, False = opponent chooses
    depth: int
    eval_cp_white: int       # eval from white's perspective
    children: list['Node'] = field(default_factory=list)
    # For opponent nodes: probability of each child being played
    child_probs: list[float] = field(default_factory=list)
    # For opponent nodes: each child's eval from the mover's perspective
    # (used to compute ease at this node)
    child_evals_for_mover: list[tuple[float, int]] = field(default_factory=list)

    def __repr__(self):
        side = "US" if self.is_our_move else "OPP"
        return f"{self.name} [{side} d={self.depth} eval={self.eval_cp_white}cp]"


# ── Build a synthetic tree ────────────────────────────────────────────────
# We're building for White. The tree represents:
#
#  Root (our move, depth 0)
#   ├─ Line A: "sharp" — leads to positions where opponent blunders often
#   │   eval is slightly worse for us, but opponent ease is LOW
#   └─ Line B: "solid" — objectively better eval, but opponent ease is HIGH
#       (they can't really go wrong)

def build_test_tree() -> Node:
    root = Node("root", is_our_move=True, depth=0, eval_cp_white=20)

    # ── LINE A: Sharp / Tricky ──
    # Our move leads to a position where we're +10cp, but opponent faces
    # a hard decision.  We test two levels of opponent difficulty.

    a_after_our = Node("A-opp-d1", is_our_move=False, depth=1, eval_cp_white=10)
    # Opponent's choices at depth 1: best is +10 for them (= -10 for us = eval_cp_white +10)
    # but the popular move is much worse
    a_after_our.child_evals_for_mover = [
        (0.55, 40),    # most popular: +40cp for mover (bad for us: white is -40)
        (0.25, -30),   # second: -30cp for mover (good for us: white is +30)
        (0.15, -80),   # third: outright blunder for mover (white is +80)
        (0.05, -120),  # rare: terrible for mover (white is +120)
    ]
    a_after_our.child_probs = [0.55, 0.25, 0.15, 0.05]

    # Continue the line: after opponent's most popular move (+40cp for them)
    a_d2_popular = Node("A-us-d2-pop", is_our_move=True, depth=2, eval_cp_white=-40)
    a_d2_blunder = Node("A-us-d2-blun", is_our_move=True, depth=2, eval_cp_white=30)
    a_d2_worse   = Node("A-us-d2-worse", is_our_move=True, depth=2, eval_cp_white=80)
    a_d2_rare    = Node("A-us-d2-rare", is_our_move=True, depth=2, eval_cp_white=120)

    # From a_d2_popular (our move at d2), we have one continuation
    a_d3_opp = Node("A-opp-d3", is_our_move=False, depth=3, eval_cp_white=-30)
    a_d3_opp.child_evals_for_mover = [
        (0.60, 50),   # popular: mover gets +50
        (0.30, -20),  # decent: mover gets -20
        (0.10, -90),  # blunder: mover loses 90
    ]
    a_d3_opp.child_probs = [0.60, 0.30, 0.10]
    a_d2_popular.children = [a_d3_opp]

    # From a_d2_blunder, another opponent node
    a_d3_opp2 = Node("A-opp-d3b", is_our_move=False, depth=3, eval_cp_white=40)
    a_d3_opp2.child_evals_for_mover = [
        (0.50, 20),   # popular
        (0.30, -40),  # worse
        (0.20, -100), # blunder
    ]
    a_d3_opp2.child_probs = [0.50, 0.30, 0.20]
    a_d2_blunder.children = [a_d3_opp2]

    a_after_our.children = [a_d2_popular, a_d2_blunder, a_d2_worse, a_d2_rare]

    # ── LINE B: Solid / Easy ──
    # Our move leads to +30cp for us, but the opponent always finds good moves.

    b_after_our = Node("B-opp-d1", is_our_move=False, depth=1, eval_cp_white=30)
    # Opponent's choices: all are close to optimal (high ease for them)
    b_after_our.child_evals_for_mover = [
        (0.45, -25),  # popular: -25 for mover (white +25)
        (0.35, -30),  # second: -30 for mover (white +30) — basically equal
        (0.15, -35),  # third: slightly worse
        (0.05, -40),  # rare: marginally worse still
    ]
    b_after_our.child_probs = [0.45, 0.35, 0.15, 0.05]

    b_d2_1 = Node("B-us-d2-1", is_our_move=True, depth=2, eval_cp_white=25)
    b_d2_2 = Node("B-us-d2-2", is_our_move=True, depth=2, eval_cp_white=30)
    b_d2_3 = Node("B-us-d2-3", is_our_move=True, depth=2, eval_cp_white=35)
    b_d2_4 = Node("B-us-d2-4", is_our_move=True, depth=2, eval_cp_white=40)

    # Deeper: opponent again finds near-optimal moves
    b_d3_opp = Node("B-opp-d3", is_our_move=False, depth=3, eval_cp_white=28)
    b_d3_opp.child_evals_for_mover = [
        (0.50, -25),
        (0.30, -28),
        (0.20, -30),
    ]
    b_d3_opp.child_probs = [0.50, 0.30, 0.20]
    b_d2_1.children = [b_d3_opp]

    b_after_our.children = [b_d2_1, b_d2_2, b_d2_3, b_d2_4]

    root.children = [a_after_our, b_after_our]
    root.child_probs = []  # not used at our-move nodes

    return root


# ── Metric 1: Current MetaEase (α-blend) ─────────────────────────────────

def meta_ease_current(node: Node, meta_alpha: float = 0.35) -> float:
    """
    Replicate the current Flutter MetaEvalPolicy.

    Returns a MetaEase value [0,1] where higher = better for us.
    """
    if not node.children:
        # Leaf: if we have ease data for the mover, return 1-ease
        if node.child_evals_for_mover:
            ease = compute_ease(node.child_evals_for_mover)
            return 1.0 - ease
        return 0.5

    if node.is_our_move:
        # Pick the child with the highest propagated MetaEase
        best = -1e9
        for child in node.children:
            v = meta_ease_current(child, meta_alpha)
            best = max(best, v)
        return best
    else:
        # Opponent node: blend local ease with future
        local_ease = compute_ease(node.child_evals_for_mover) if node.child_evals_for_mover else 0.5
        opponent_difficulty = 1.0 - local_ease

        weighted_future = 0.0
        for i, child in enumerate(node.children):
            prob = node.child_probs[i] if i < len(node.child_probs) else 1.0 / len(node.children)
            weighted_future += prob * meta_ease_current(child, meta_alpha)

        return meta_alpha * opponent_difficulty + (1.0 - meta_alpha) * weighted_future


# ── Metric 2: Depth-weighted ease ────────────────────────────────────────

def meta_ease_depth_weighted(node: Node, depth_discount: float = 0.85) -> float:
    """
    Variant: explicitly discount ease contributions by depth.

    Instead of blending local + future with a fixed alpha, we accumulate
    opponent-difficulty values with a geometric discount factor per ply.

    At each opponent node we compute:
      value = opponent_difficulty × discount^depth + future_values

    At our nodes, we pick max.
    """
    if not node.children:
        if node.child_evals_for_mover:
            ease = compute_ease(node.child_evals_for_mover)
            return (1.0 - ease) * (depth_discount ** node.depth)
        return 0.5 * (depth_discount ** node.depth)

    if node.is_our_move:
        best = -1e9
        for child in node.children:
            v = meta_ease_depth_weighted(child, depth_discount)
            best = max(best, v)
        return best
    else:
        local_ease = compute_ease(node.child_evals_for_mover) if node.child_evals_for_mover else 0.5
        local_value = (1.0 - local_ease) * (depth_discount ** node.depth)

        weighted_future = 0.0
        for i, child in enumerate(node.children):
            prob = node.child_probs[i] if i < len(node.child_probs) else 1.0 / len(node.children)
            weighted_future += prob * meta_ease_depth_weighted(child, depth_discount)

        return local_value + weighted_future


# ── Metric 3: Expected CPL (centipawn loss) ──────────────────────────────

def expected_cpl_metric(node: Node, depth_discount: float = 0.90) -> float:
    """
    At each opponent node, compute the expected centipawn loss (how many cp
    the opponent loses on average vs best play), discounted by depth.

    At our nodes, pick the child that maximizes opponent's total expected CPL
    down the line.

    Returns accumulated discounted CPL (higher = opponent loses more material
    = better for us).
    """
    if not node.children:
        if node.child_evals_for_mover:
            cpl = expected_cpl(node.child_evals_for_mover)
            return cpl * (depth_discount ** node.depth)
        return 0.0

    if node.is_our_move:
        best = -1e9
        for child in node.children:
            v = expected_cpl_metric(child, depth_discount)
            best = max(best, v)
        return best
    else:
        local_cpl = expected_cpl(node.child_evals_for_mover) if node.child_evals_for_mover else 0.0
        local_value = local_cpl * (depth_discount ** node.depth)

        weighted_future = 0.0
        for i, child in enumerate(node.children):
            prob = node.child_probs[i] if i < len(node.child_probs) else 1.0 / len(node.children)
            weighted_future += prob * expected_cpl_metric(child, depth_discount)

        return local_value + weighted_future


# ── Metric 4: Eval-guarded CPL ───────────────────────────────────────────

def eval_guarded_cpl(node: Node, is_white: bool = True,
                     min_eval_for_us: int = -100,
                     depth_discount: float = 0.90) -> float:
    """
    Like expected_cpl_metric but we also penalize if our eval drops below
    a threshold. This prevents picking "tricky but objectively lost" lines.

    Returns: expected opponent CPL - penalty for our eval being bad.
    """
    eval_for_us = node.eval_cp_white if is_white else -node.eval_cp_white
    eval_penalty = max(0, min_eval_for_us - eval_for_us) * 0.1

    if not node.children:
        if node.child_evals_for_mover:
            cpl = expected_cpl(node.child_evals_for_mover)
            return cpl * (depth_discount ** node.depth) - eval_penalty
        return -eval_penalty

    if node.is_our_move:
        best = -1e9
        for child in node.children:
            v = eval_guarded_cpl(child, is_white, min_eval_for_us, depth_discount)
            best = max(best, v)
        return best - eval_penalty
    else:
        local_cpl = expected_cpl(node.child_evals_for_mover) if node.child_evals_for_mover else 0.0
        local_value = local_cpl * (depth_discount ** node.depth) - eval_penalty

        weighted_future = 0.0
        for i, child in enumerate(node.children):
            prob = node.child_probs[i] if i < len(node.child_probs) else 1.0 / len(node.children)
            weighted_future += prob * eval_guarded_cpl(child, is_white, min_eval_for_us, depth_discount)

        return local_value + weighted_future


# ── Reporting ─────────────────────────────────────────────────────────────

def report_ease_at_nodes(tree: Node, indent: int = 0):
    """Print ease and CPL at every opponent node."""
    prefix = "  " * indent
    if not tree.is_our_move and tree.child_evals_for_mover:
        ease = compute_ease(tree.child_evals_for_mover)
        cpl = expected_cpl(tree.child_evals_for_mover)
        print(f"{prefix}{tree.name}: ease={ease:.3f} (opponent difficulty={1-ease:.3f}), "
              f"expected_CPL={cpl:.1f}cp")
    elif tree.is_our_move:
        print(f"{prefix}{tree.name}: (our move, eval={tree.eval_cp_white}cp)")
    for child in tree.children:
        report_ease_at_nodes(child, indent + 1)


def main():
    tree = build_test_tree()

    print("=" * 70)
    print("TREE STRUCTURE — Ease & CPL at each opponent node")
    print("=" * 70)
    report_ease_at_nodes(tree)

    print()
    print("=" * 70)
    print("COMPARING METRICS — Which line does each metric prefer?")
    print("=" * 70)

    line_a = tree.children[0]  # sharp/tricky
    line_b = tree.children[1]  # solid

    print(f"\nLine A (Sharp): eval after our move = {line_a.eval_cp_white}cp")
    print(f"Line B (Solid): eval after our move = {line_b.eval_cp_white}cp")
    print()

    for alpha in [0.20, 0.35, 0.50, 0.70]:
        va = meta_ease_current(line_a, alpha)
        vb = meta_ease_current(line_b, alpha)
        winner = "A (sharp)" if va > vb else "B (solid)"
        print(f"  Current MetaEase (α={alpha:.2f}):  A={va:.4f}  B={vb:.4f}  → {winner}")

    print()

    for discount in [0.70, 0.85, 0.95]:
        va = meta_ease_depth_weighted(line_a, discount)
        vb = meta_ease_depth_weighted(line_b, discount)
        winner = "A (sharp)" if va > vb else "B (solid)"
        print(f"  Depth-weighted (γ={discount:.2f}):  A={va:.4f}  B={vb:.4f}  → {winner}")

    print()

    for discount in [0.80, 0.90, 1.00]:
        va = expected_cpl_metric(line_a, discount)
        vb = expected_cpl_metric(line_b, discount)
        winner = "A (sharp)" if va > vb else "B (solid)"
        print(f"  Expected CPL (γ={discount:.2f}):    A={va:.1f}cp  B={vb:.1f}cp  → {winner}")

    print()

    for min_eval in [-50, 0, 20]:
        va = eval_guarded_cpl(line_a, is_white=True, min_eval_for_us=min_eval)
        vb = eval_guarded_cpl(line_b, is_white=True, min_eval_for_us=min_eval)
        winner = "A (sharp)" if va > vb else "B (solid)"
        print(f"  Eval-guarded CPL (min={min_eval:+d}cp): A={va:.1f}  B={vb:.1f}  → {winner}")

    # ── Sensitivity analysis: how does metaAlpha change behavior? ────────
    print()
    print("=" * 70)
    print("SENSITIVITY: Effect of metaAlpha on current MetaEase")
    print("=" * 70)
    print()
    print("metaAlpha controls how much weight is on LOCAL opponent difficulty")
    print("vs FUTURE subtree difficulty.  Higher α = more emphasis on the")
    print("immediate position, lower α = more emphasis on what happens later.")
    print()

    for alpha in [x / 20.0 for x in range(1, 20)]:
        va = meta_ease_current(line_a, alpha)
        vb = meta_ease_current(line_b, alpha)
        bar_a = "█" * int(va * 40)
        bar_b = "█" * int(vb * 40)
        pick = "A" if va > vb else "B"
        print(f"  α={alpha:.2f}  A={va:.3f} {bar_a:40s}  B={vb:.3f} {bar_b:40s}  pick={pick}")

    # ── What "expected centipawns" actually tells us ─────────────────────
    print()
    print("=" * 70)
    print("UNDERSTANDING Expected CPL")
    print("=" * 70)
    print()

    print("At Line A, depth 1 opponent node:")
    a_evals = tree.children[0].child_evals_for_mover
    print(f"  Moves: {a_evals}")
    print(f"  Ease: {compute_ease(a_evals):.3f}")
    print(f"  Expected CPL: {expected_cpl(a_evals):.1f}cp")
    print(f"  → Opponent is expected to lose {expected_cpl(a_evals):.1f}cp vs best play")
    print()

    print("At Line B, depth 1 opponent node:")
    b_evals = tree.children[1].child_evals_for_mover
    print(f"  Moves: {b_evals}")
    print(f"  Ease: {compute_ease(b_evals):.3f}")
    print(f"  Expected CPL: {expected_cpl(b_evals):.1f}cp")
    print(f"  → Opponent is expected to lose {expected_cpl(b_evals):.1f}cp vs best play")

    # ── Compare the two ease formulas numerically ────────────────────────
    print()
    print("=" * 70)
    print("EASE vs CPL — Numerical comparison across synthetic positions")
    print("=" * 70)
    print()
    print(f"{'Position':30s} {'Ease':>6s} {'1-Ease':>6s} {'CPL':>8s}")
    print("-" * 55)

    test_positions = [
        ("All moves equal",        [(0.50, 0), (0.30, 0), (0.20, 0)]),
        ("Clear best, rest close",  [(0.40, 50), (0.35, 30), (0.25, 20)]),
        ("One trap move",           [(0.60, -80), (0.30, 50), (0.10, 40)]),
        ("Big blunder common",      [(0.70, -150), (0.20, 50), (0.10, 40)]),
        ("Only move is good",       [(0.90, 50), (0.10, -200)]),
        ("Spread of quality",       [(0.30, 100), (0.25, 50), (0.25, -50), (0.20, -100)]),
        ("Rare brilliant move",     [(0.05, 200), (0.50, 0), (0.45, -10)]),
    ]

    for name, evals in test_positions:
        e = compute_ease(evals)
        c = expected_cpl(evals)
        print(f"{name:30s} {e:6.3f} {1-e:6.3f} {c:8.1f}cp")


if __name__ == "__main__":
    main()
