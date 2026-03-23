#!/usr/bin/env python3
"""
Extended dry-run: scenarios where metrics disagree.

Scenario 1: "Deep trap" vs "Immediate trap"
  Line A: opponent has a hard decision at depth 1 but easy sailing after
  Line B: depth 1 is easy for opponent, but depth 3 and 5 are devastating

Scenario 2: "Objectively equal but tricky" vs "Slightly better but sterile"
  Tests the eval-guard vs pure CPL tradeoff

Scenario 3: Real-ish Sicilian vs 1.e4 e5 comparison
  Sicilian lines are objectively equal but opponents blunder more
  Italian is slightly better but opponents know the theory
"""

import math
from dataclasses import dataclass, field

EASE_ALPHA = 1.0 / 3.0
EASE_BETA = 1.5
Q_SIGMOID_K = 0.004


def score_to_q(cp: int) -> float:
    if abs(cp) > 9000:
        return 1.0 if cp > 0 else -1.0
    wp = 1.0 / (1.0 + math.exp(-Q_SIGMOID_K * cp))
    return 2.0 * wp - 1.0


def compute_ease(move_evals: list[tuple[float, int]]) -> float:
    if not move_evals:
        return 0.5
    best_cp = max(cp for _, cp in move_evals)
    q_max = score_to_q(best_cp)
    swr = 0.0
    for prob, cp in move_evals:
        if prob < 0.01:
            continue
        q_val = score_to_q(cp)
        regret = max(0.0, q_max - q_val)
        swr += (prob ** EASE_BETA) * regret
    ease = 1.0 - (swr / 2.0) ** EASE_ALPHA
    return max(0.0, min(1.0, ease))


def expected_cpl(move_evals: list[tuple[float, int]]) -> float:
    if not move_evals:
        return 0.0
    best_cp = max(cp for _, cp in move_evals)
    return sum(prob * max(0, best_cp - cp) for prob, cp in move_evals)


@dataclass
class Node:
    name: str
    is_our_move: bool
    depth: int
    eval_cp_white: int
    children: list['Node'] = field(default_factory=list)
    child_probs: list[float] = field(default_factory=list)
    child_evals_for_mover: list[tuple[float, int]] = field(default_factory=list)


# ── Metrics ──────────────────────────────────────────────────────────────

def meta_ease_current(node: Node, alpha: float = 0.35) -> float:
    if not node.children:
        if node.child_evals_for_mover:
            return 1.0 - compute_ease(node.child_evals_for_mover)
        return 0.5

    if node.is_our_move:
        return max(meta_ease_current(c, alpha) for c in node.children)
    else:
        local_ease = compute_ease(node.child_evals_for_mover) if node.child_evals_for_mover else 0.5
        opp_diff = 1.0 - local_ease
        future = sum(
            (node.child_probs[i] if i < len(node.child_probs) else 1.0 / len(node.children))
            * meta_ease_current(c, alpha)
            for i, c in enumerate(node.children)
        )
        return alpha * opp_diff + (1.0 - alpha) * future


def expected_cpl_total(node: Node, gamma: float = 0.90) -> float:
    """Sum of depth-discounted expected CPL at every opponent node."""
    if not node.children:
        if node.child_evals_for_mover:
            return expected_cpl(node.child_evals_for_mover) * (gamma ** node.depth)
        return 0.0

    if node.is_our_move:
        return max(expected_cpl_total(c, gamma) for c in node.children)
    else:
        local = expected_cpl(node.child_evals_for_mover) * (gamma ** node.depth) if node.child_evals_for_mover else 0.0
        future = sum(
            (node.child_probs[i] if i < len(node.child_probs) else 1.0 / len(node.children))
            * expected_cpl_total(c, gamma)
            for i, c in enumerate(node.children)
        )
        return local + future


def eval_plus_cpl(node: Node, is_white: bool = True,
                  cpl_weight: float = 0.5, gamma: float = 0.90) -> float:
    """
    Hybrid: normalized eval + weighted expected CPL.

    Tries to balance "objectively good" with "opponent will blunder."
    """
    eval_for_us = node.eval_cp_white if is_white else -node.eval_cp_white
    win_prob = 1.0 / (1.0 + math.exp(-0.00368208 * eval_for_us))

    cpl_total = expected_cpl_total(node, gamma)
    cpl_norm = 1.0 - math.exp(-0.01 * cpl_total)  # normalize to [0,1]

    return (1.0 - cpl_weight) * win_prob + cpl_weight * cpl_norm


# ── Scenario 1: Deep trap vs Immediate trap ─────────────────────────────

def build_scenario1():
    """
    Line A: Big immediate trap (d=1), then easy (d=3)
    Line B: Easy d=1, but devastating d=3
    """
    root = Node("root", True, 0, 15)

    # LINE A: immediate trap
    a = Node("A-opp-d1", False, 1, 10)
    a.child_evals_for_mover = [
        (0.60, -80),   # popular: huge blunder
        (0.25, 50),    # best
        (0.15, 30),
    ]
    a.child_probs = [0.60, 0.25, 0.15]

    a_d2 = Node("A-us-d2", True, 2, 80)
    # depth 3: easy for opponent (they found theory)
    a_d3 = Node("A-opp-d3", False, 3, 75)
    a_d3.child_evals_for_mover = [
        (0.50, -72),   # all moves close to best
        (0.30, -75),
        (0.20, -78),
    ]
    a_d3.child_probs = [0.50, 0.30, 0.20]
    a_d2.children = [a_d3]
    a.children = [a_d2, Node("A-us-d2b", True, 2, -50), Node("A-us-d2c", True, 2, -30)]

    # LINE B: no immediate trap
    b = Node("B-opp-d1", False, 1, 20)
    b.child_evals_for_mover = [
        (0.45, -18),   # all close to optimal
        (0.35, -20),
        (0.20, -22),
    ]
    b.child_probs = [0.45, 0.35, 0.20]

    b_d2 = Node("B-us-d2", True, 2, 18)
    # depth 3: devastating for opponent
    b_d3 = Node("B-opp-d3", False, 3, 25)
    b_d3.child_evals_for_mover = [
        (0.55, -150),  # popular: terrible blunder
        (0.25, 40),    # best
        (0.20, -50),   # also bad
    ]
    b_d3.child_probs = [0.55, 0.25, 0.20]
    b_d2.children = [b_d3]
    b.children = [b_d2, Node("B-us-d2b", True, 2, 20), Node("B-us-d2c", True, 2, 22)]

    root.children = [a, b]
    return root


# ── Scenario 2: Equal but tricky vs slightly better but sterile ─────────

def build_scenario2():
    """
    Line A: eval ≈ 0, but opponent blunders at every turn
    Line B: eval ≈ +40, but opponent plays near-optimally
    """
    root = Node("root", True, 0, 10)

    # LINE A: Equal but tricky at every opponent node
    a1 = Node("A-opp-d1", False, 1, 0)
    a1.child_evals_for_mover = [
        (0.50, -100),  # popular: big mistake
        (0.30, 20),    # best
        (0.20, -50),   # also bad
    ]
    a1.child_probs = [0.50, 0.30, 0.20]
    a1_us = Node("A-us-d2", True, 2, 100)

    a3 = Node("A-opp-d3", False, 3, 90)
    a3.child_evals_for_mover = [
        (0.45, -120),  # popular: mistake again
        (0.35, 30),    # best
        (0.20, -30),   # mediocre
    ]
    a3.child_probs = [0.45, 0.35, 0.20]
    a1_us.children = [a3]
    a1.children = [a1_us, Node("A-us-d2b", True, 2, -20), Node("A-us-d2c", True, 2, -50)]

    # LINE B: Better eval but sterile
    b1 = Node("B-opp-d1", False, 1, 40)
    b1.child_evals_for_mover = [
        (0.40, -38),   # all near-optimal
        (0.35, -40),
        (0.25, -42),
    ]
    b1.child_probs = [0.40, 0.35, 0.25]
    b1_us = Node("B-us-d2", True, 2, 38)

    b3 = Node("B-opp-d3", False, 3, 40)
    b3.child_evals_for_mover = [
        (0.45, -38),   # all near-optimal
        (0.35, -40),
        (0.20, -43),
    ]
    b3.child_probs = [0.45, 0.35, 0.20]
    b1_us.children = [b3]
    b1.children = [b1_us, Node("B-us-d2b", True, 2, 40), Node("B-us-d2c", True, 2, 42)]

    root.children = [a1, b1]
    return root


def analyze_scenario(name: str, tree: Node):
    print(f"\n{'=' * 70}")
    print(f"  {name}")
    print(f"{'=' * 70}")

    a = tree.children[0]
    b = tree.children[1]

    # Show ease at each opponent node
    def show_ease(node, indent=0):
        pfx = "  " * indent
        if not node.is_our_move and node.child_evals_for_mover:
            e = compute_ease(node.child_evals_for_mover)
            c = expected_cpl(node.child_evals_for_mover)
            print(f"  {pfx}{node.name}: ease={e:.3f}, CPL={c:.1f}cp, eval={node.eval_cp_white}cp")
        for child in node.children:
            show_ease(child, indent + 1)

    show_ease(tree)

    print()
    print(f"  {'Metric':<35s} {'Line A':>10s} {'Line B':>10s} {'Pick':>6s}")
    print(f"  {'-'*65}")

    metrics = []

    for alpha in [0.20, 0.35, 0.50]:
        va = meta_ease_current(a, alpha)
        vb = meta_ease_current(b, alpha)
        pick = "A" if va > vb else "B"
        metrics.append((f"MetaEase (α={alpha})", va, vb, pick))

    for gamma in [0.80, 0.90, 1.00]:
        va = expected_cpl_total(a, gamma)
        vb = expected_cpl_total(b, gamma)
        pick = "A" if va > vb else "B"
        metrics.append((f"Expected CPL (γ={gamma})", va, vb, pick))

    for w in [0.3, 0.5, 0.7]:
        va = eval_plus_cpl(a, cpl_weight=w)
        vb = eval_plus_cpl(b, cpl_weight=w)
        pick = "A" if va > vb else "B"
        metrics.append((f"Eval+CPL (cpl_w={w})", va, vb, pick))

    for m_name, va, vb, pick in metrics:
        print(f"  {m_name:<35s} {va:>10.4f} {vb:>10.4f} {pick:>6s}")


# ── Scenario 3: What about cumulative probability? ───────────────────────

def build_scenario3():
    """
    Line A: Very tricky but only 15% of opponents reach here
    Line B: Moderately tricky but 80% of opponents enter this line
    Tests whether we should weight by probability of reaching the position.
    """
    root = Node("root", True, 0, 10)

    # LINE A: Rare but tricky (think: some gambit)
    a1 = Node("A-opp-d1", False, 1, 5)
    a1.child_evals_for_mover = [
        (0.65, -120),  # most popular: huge mistake
        (0.25, 30),    # best
        (0.10, -40),
    ]
    a1.child_probs = [0.65, 0.25, 0.10]
    a1.children = []  # leaf for simplicity

    # LINE B: Common but mildly tricky
    b1 = Node("B-opp-d1", False, 1, 15)
    b1.child_evals_for_mover = [
        (0.50, -30),   # mildly bad
        (0.30, 20),    # best
        (0.20, -10),
    ]
    b1.child_probs = [0.50, 0.30, 0.20]
    b1.children = []  # leaf

    root.children = [a1, b1]
    return root


def analyze_scenario3():
    print(f"\n{'=' * 70}")
    print("  Scenario 3: Rare-but-tricky vs Common-but-mild")
    print(f"{'=' * 70}")

    tree = build_scenario3()
    a = tree.children[0]
    b = tree.children[1]

    a_ease = compute_ease(a.child_evals_for_mover)
    b_ease = compute_ease(b.child_evals_for_mover)
    a_cpl = expected_cpl(a.child_evals_for_mover)
    b_cpl = expected_cpl(b.child_evals_for_mover)

    print(f"\n  Line A (rare gambit):  ease={a_ease:.3f}, CPL={a_cpl:.1f}cp")
    print(f"  Line B (main line):   ease={b_ease:.3f}, CPL={b_cpl:.1f}cp")
    print()
    print("  Without probability weighting, all metrics prefer Line A.")
    print("  But 80% of opponents play into Line B!")
    print()
    print("  Probability-weighted expected CPL:")
    print(f"    Line A (prob=0.15): {0.15 * a_cpl:.1f}cp expected gain")
    print(f"    Line B (prob=0.80): {0.80 * b_cpl:.1f}cp expected gain")
    pick = "A" if 0.15 * a_cpl > 0.80 * b_cpl else "B"
    print(f"    → Pick: {pick}")
    print()
    print("  This is the KEY insight for 'expected centipawns' as a metric:")
    print("  CPL × probability = expected centipawn gain across ALL opponents.")
    print("  This naturally weights common lines more than rare ones.")


# ── Main ─────────────────────────────────────────────────────────────────

def main():
    print("╔══════════════════════════════════════════════════════════════════════╗")
    print("║         MetaEase Dry-Run: Comparing Alternative Metrics            ║")
    print("╚══════════════════════════════════════════════════════════════════════╝")

    analyze_scenario("Scenario 1: Deep Trap vs Immediate Trap", build_scenario1())
    analyze_scenario("Scenario 2: Equal-but-Tricky vs Better-but-Sterile", build_scenario2())
    analyze_scenario3()

    # ── Summary of findings ──────────────────────────────────────────────
    print()
    print("=" * 70)
    print("SUMMARY: What metric should we use?")
    print("=" * 70)
    print("""
Current MetaEase:
  ✓ Non-greedy: looks through the whole line
  ✓ Implicit depth discount via α-blending
  ✗ The ease formula is non-linear (cube root), making it hard to interpret
  ✗ α couples "local vs future" weighting with depth discount
  ✗ Doesn't naturally incorporate cumulative probability
  ✗ Normalized to [0,1] — loses magnitude information

Expected CPL (centipawn loss):
  ✓ Directly interpretable: "opponent loses X cp on average"
  ✓ Additive: total line CPL = sum of per-node CPLs
  ✓ Naturally composable with probability weighting
  ✓ Can be depth-discounted independently of aggregation
  ✗ Linear in cp difference — doesn't account for diminishing returns
     (losing 200cp vs 100cp is not 2× as bad in practice)
  ✗ Doesn't have a built-in eval guard

Recommended hybrid: "Expected Centipawn Advantage" (ECA)
  At each opponent node:
    ECA = probability_of_reaching × Σ(prob_i × max(0, best_cp - move_cp_i))
  Along a line:
    Line_ECA = Σ(γ^depth × ECA_at_each_opponent_node)
  Selection:
    Pick our move that maximizes Line_ECA, subject to eval guard
    (reject any line where our eval drops below a threshold)

  This gives you:
  ✓ Probability-weighted (common lines matter more)
  ✓ Depth-discounted (closer positions matter more)
  ✓ Directly interpretable (total expected cp gain vs perfect opponent)
  ✓ Eval-guarded (won't pick losing positions just because they're tricky)
""")


if __name__ == "__main__":
    main()
