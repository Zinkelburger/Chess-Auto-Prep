"""
Simple opening search - find positions where opponent is likely to blunder.

No complicated tree structures. Just:
1. Start from a position
2. Get Maia2 move probabilities
3. Evaluate each child position
4. If we find a good expected value swing, save it
5. Recursively explore promising positions
"""

import chess
from typing import List
from dataclasses import dataclass


@dataclass
class InterestingPosition:
    """A position we found that's interesting."""
    line: List[str]  # SAN moves from starting position
    fen: str
    probability: float  # Cumulative probability of reaching this position
    expected_value: float  # Expected value from your perspective (cp)


def search_for_tricks(
    board: chess.Board,
    maia2_model,
    stockfish_engine,
    my_color: chess.Color,
    player_elo: int = 1500,
    opponent_elo: int = 1500,
    max_depth: int = 20,
    min_probability: float = 0.10,
    min_ev_cp: float = 50.0,
    top_n_candidates: int = 8,
    my_move_threshold_cp: float = 50.0,
    opponent_min_prob: float = 0.20,
    current_depth: int = 0,
    current_line: List[str] = None,
    current_probability: float = 1.0,
    root_eval: float = None
) -> List[InterestingPosition]:
    """
    Simple recursive search for tricky positions.

    Args:
        board: Current position
        maia2_model: Maia2 model for move probabilities
        stockfish_engine: Stockfish for evaluation
        my_color: Your color
        player_elo: Your ELO
        opponent_elo: Opponent's ELO
        max_depth: Maximum depth to search
        min_probability: Minimum cumulative probability to explore
        min_ev_cp: Minimum expected value to consider interesting (cp)
        top_n_candidates: Top N moves by probability to evaluate
        my_move_threshold_cp: Explore your moves within this many cp of best move
        opponent_min_prob: Minimum probability for opponent moves (e.g., 0.20 = 20%)
        current_depth: Current depth (internal use)
        current_line: Current move sequence (internal use)
        current_probability: Cumulative probability (internal use)
        root_eval: Root position eval for pruning (internal use)

    Returns:
        List of interesting positions found
    """
    if current_line is None:
        current_line = []

    interesting_positions = []

    # Get root eval on first call
    if root_eval is None:
        root_eval = stockfish_engine.evaluate(board, depth=20, pov_color=my_color)
        if root_eval is None:
            root_eval = 0.0
        print(f"  Root eval: {root_eval:+.1f} cp")

    # Progress indicator
    if current_depth == 0:
        print(f"\n  Starting search from position...")
    elif current_depth % 2 == 0 and current_probability > 0.01:
        print(f"  Exploring depth {current_depth}, prob {current_probability:.1%}...")

    # Stop if we've gone too deep
    if current_depth >= max_depth:
        return interesting_positions

    # Stop if probability is too low to matter
    if current_probability < min_probability * 0.01:  # 1% of threshold
        return interesting_positions

    is_my_turn = (board.turn == my_color)

    # Get move probabilities
    if is_my_turn:
        current_elo = player_elo
        opposing_elo = opponent_elo
    else:
        current_elo = opponent_elo
        opposing_elo = player_elo

    move_probs = maia2_model.get_move_probabilities(
        board,
        player_elo=current_elo,
        opponent_elo=opposing_elo,
        min_probability=min_probability
    )

    if not move_probs:
        return interesting_positions

    # Sort by probability
    sorted_moves = sorted(move_probs.items(), key=lambda x: x[1], reverse=True)

    # Evaluate candidates and filter
    children_data = []

    if is_my_turn:
        # Your turn: Evaluate top N candidates, keep those within threshold of best
        candidates = sorted_moves[:top_n_candidates]

        # Evaluate all candidates
        evaluated = []
        for move_san, prob in candidates:
            child_board = board.copy()
            child_board.push_san(move_san)
            child_eval = stockfish_engine.evaluate(child_board, depth=20, pov_color=my_color)
            if child_eval is None:
                child_eval = 0.0
            evaluated.append((move_san, prob, child_eval, child_board))

        if not evaluated:
            return interesting_positions

        # Find best eval
        best_eval = max(ev for _, _, ev, _ in evaluated)

        # Keep moves within threshold of best
        for move_san, prob, child_eval, child_board in evaluated:
            if child_eval >= best_eval - my_move_threshold_cp:
                children_data.append((move_san, prob, child_eval, child_board))
            else:
                print(f"    [PRUNED] {move_san}: {child_eval:+.0f} cp, {best_eval - child_eval:.0f} cp worse than best")

    else:
        # Opponent turn: All moves with probability >= threshold
        for move_san, prob in sorted_moves:
            if prob < opponent_min_prob:
                break  # Already sorted, so we can stop

            child_board = board.copy()
            child_board.push_san(move_san)
            child_eval = stockfish_engine.evaluate(child_board, depth=20, pov_color=my_color)
            if child_eval is None:
                child_eval = 0.0

            children_data.append((move_san, prob, child_eval, child_board))

    if not children_data:
        return interesting_positions

    # Calculate expected value (probability-weighted)
    total_prob = sum(prob for _, prob, _, _ in children_data)
    expected_value = sum(prob * ev for _, prob, ev, _ in children_data) / total_prob

    # Check if this is an interesting opponent position
    # (expected value is good for you after opponent's likely moves)
    if not is_my_turn and current_depth > 0:
        # If expected value is good enough, save this position and STOP
        if expected_value >= min_ev_cp:
            interesting_positions.append(InterestingPosition(
                line=current_line.copy(),
                fen=board.fen(),
                probability=current_probability,
                expected_value=expected_value
            ))
            print(f"  [FOUND] Depth {current_depth}, Prob {current_probability:.1%}, EV {expected_value:+.0f} cp: {' '.join(current_line)}")
            return interesting_positions  # STOP - we found what we wanted

    # Recursively explore children
    for move_san, prob, child_eval, child_board in children_data:
        # Skip low-probability moves
        child_probability = current_probability * prob
        if child_probability < min_probability * 0.01:
            continue

        # Recurse
        new_line = current_line + [move_san]
        child_positions = search_for_tricks(
            board=child_board,
            maia2_model=maia2_model,
            stockfish_engine=stockfish_engine,
            my_color=my_color,
            player_elo=player_elo,
            opponent_elo=opponent_elo,
            max_depth=max_depth,
            min_probability=min_probability,
            min_ev_cp=min_ev_cp,
            top_n_candidates=top_n_candidates,
            my_move_threshold_cp=my_move_threshold_cp,
            opponent_min_prob=opponent_min_prob,
            current_depth=current_depth + 1,
            current_line=new_line,
            current_probability=child_probability,
            root_eval=root_eval
        )

        interesting_positions.extend(child_positions)

    return interesting_positions
