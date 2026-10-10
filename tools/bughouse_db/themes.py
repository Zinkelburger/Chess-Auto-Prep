"""Theme tags for mined bughouse puzzles, after lichess-puzzler's `cook`.

`tag_themes` replays a verified line with frozen reserves and returns tags in
lila's camelCase vocabulary, so a trainer page can reuse the familiar names:

  * `mateIn1`..`mateIn5` and `mate` when the line ends in checkmate, then at
    most one mate pattern in lila's order of precedence: `smotheredMate`,
    `backRankMate`, `anastasiaMate`, `hookMate`, `arabianMate`, `bodenMate` /
    `doubleBishopMate`, `dovetailMate`. Geometry is lila's, from the solver's
    point of view on the final board;
  * `crushing` (final eval above 600 cp, or a mate score) or `advantage` for a
    line that wins without mating;
  * `doubleCheck`, `discoveredCheck`, `promotion`: some solver move does it;
  * `sacrifice`: the solver is down two or more points against the start after
    a later solver move, unless a defender's reply promoted. Material counts a
    side's reserve too, so a drop is not a sacrifice by itself but a dropped
    piece that gets taken is;
  * `quietMove`: a solver move before the last that neither gives nor escapes
    check, captures nothing, attacks no enemy piece from its square, is no
    advanced pawn move and is not a king move;
  * bughouse: `drop` (some solver move is a drop), `dropMate` (the mating move
    is a drop), `contactMate` (the mating piece stands next to the king);
  * `long`: four or more solver moves.
"""

from __future__ import annotations

import chess
from chess import BISHOP, KING, KNIGHT, PAWN, QUEEN, ROOK, square_distance, square_file, square_rank
from chess.variant import CrazyhouseBoard

from .frozen import replay

VALUES = {PAWN: 1, KNIGHT: 3, BISHOP: 3, ROOK: 5, QUEEN: 9}


def material_count(board: CrazyhouseBoard, side: chess.Color) -> int:
    """Pieces on the board plus the pieces in hand."""
    pocket = board.pockets[side]
    return sum((len(board.pieces(pt, side)) + pocket.count(pt)) * value for pt, value in VALUES.items())


def material_diff(board: CrazyhouseBoard, side: chess.Color) -> int:
    return material_count(board, side) - material_count(board, not side)


def tag_themes(fen: str, line: list[str], cp: int | None) -> list[str]:
    boards = replay(fen, line)
    moves = [chess.Move.from_uci(u) for u in line]
    pov = boards[0].turn
    final = boards[-1]
    solver = range(0, len(line), 2)
    tags: list[str] = []

    mated = final.is_checkmate()
    if mated:
        n = (len(line) + 1) // 2
        tags += [f"mateIn{min(n, 5)}", "mate"]
        pattern = _mate_pattern(final, moves[-1], pov)
        if pattern:
            tags.append(pattern)
    elif cp is None or cp > 600:
        tags.append("crushing")
    else:
        tags.append("advantage")

    if any(len(boards[i + 1].checkers()) > 1 for i in solver):
        tags.append("doubleCheck")
    if any(boards[i + 1].checkers() and moves[i].to_square not in boards[i + 1].checkers() for i in solver):
        tags.append("discoveredCheck")
    if _sacrifice(boards, moves, pov):
        tags.append("sacrifice")
    if any(moves[i].promotion for i in solver):
        tags.append("promotion")
    if any(_quiet(boards[i], boards[i + 1], moves[i], pov) for i in solver if i < len(line) - 1):
        tags.append("quietMove")
    if any(moves[i].drop for i in solver):
        tags.append("drop")
    if mated:
        if moves[-1].drop:
            tags.append("dropMate")
        king = final.king(not pov)
        if moves[-1].to_square in final.checkers() and square_distance(moves[-1].to_square, king) == 1:
            tags.append("contactMate")
    if len(solver) >= 4:
        tags.append("long")
    return tags


# ── Helpers ───────────────────────────────────────────────────────────


def _sacrifice(boards: list[CrazyhouseBoard], moves: list[chess.Move], pov: chess.Color) -> bool:
    initial = material_diff(boards[0], pov)
    for i in range(2, len(moves), 2):  # after the second solver move onwards
        if material_diff(boards[i + 1], pov) - initial <= -2:
            return not any(m.promotion for m in moves[1::2])
    return False


def _quiet(before: CrazyhouseBoard, after: CrazyhouseBoard, move: chess.Move, pov: chess.Color) -> bool:
    if after.is_check() or before.is_check() or before.is_capture(move):
        return False
    if any(p and p.color != pov for p in (after.piece_at(s) for s in after.attacks(move.to_square))):
        return False
    piece = after.piece_type_at(move.to_square)
    if piece == KING or move.promotion:
        return False
    if piece == PAWN:
        rank = square_rank(move.to_square)
        if (rank >= 4) if pov == chess.WHITE else (rank <= 3):
            return False
    return True


def _mate_pattern(board: CrazyhouseBoard, move: chess.Move, pov: chess.Color) -> str | None:
    king = board.king(not pov)
    assert king is not None
    moved = board.piece_type_at(move.to_square)
    if _smothered(board, king, pov):
        return "smotheredMate"
    if _back_rank(board, king, pov):
        return "backRankMate"
    if _anastasia(board, king, move, moved, pov):
        return "anastasiaMate"
    if _hook(board, king, move, moved, pov):
        return "hookMate"
    if _arabian(board, king, move, moved, pov):
        return "arabianMate"
    bishops = _boden_or_double_bishop(board, king, pov)
    if bishops:
        return bishops
    if _dovetail(board, king, move, moved, pov):
        return "dovetailMate"
    return None


def _ring(king: int) -> list[int]:
    return [s for s in chess.SQUARES if square_distance(s, king) == 1]


def _smothered(board: CrazyhouseBoard, king: int, pov: chess.Color) -> bool:
    for checker in board.checkers():
        if board.piece_type_at(checker) == KNIGHT:
            for escape in _ring(king):
                blocker = board.piece_at(escape)
                if not blocker or blocker.color == pov:
                    return False
            return True
    return False


def _back_rank(board: CrazyhouseBoard, king: int, pov: chess.Color) -> bool:
    back_rank = 7 if pov else 0
    if square_rank(king) != back_rank:
        return False
    step = -8 if pov else 8
    squares = [king + step]
    if square_file(king) < 7:
        squares.append(king + step + 1)
    if square_file(king) > 0:
        squares.append(king + step - 1)
    for square in squares:
        piece = board.piece_at(square)
        if piece is None or piece.color == pov or board.attackers(pov, square):
            return False
    return any(square_rank(c) == back_rank for c in board.checkers())


def _anastasia(board: CrazyhouseBoard, king: int, move: chess.Move, moved: int, pov: chess.Color) -> bool:
    if square_file(king) not in (0, 7) or square_rank(king) in (0, 7):
        return False
    if square_file(move.to_square) != square_file(king) or moved not in (QUEEN, ROOK):
        return False
    inward = 1 if square_file(king) == 0 else -1
    blocker = board.piece_at(king + inward)
    if blocker is None or blocker.color == pov:
        return False
    knight = board.piece_at(king + 3 * inward)
    return knight is not None and knight.color == pov and knight.piece_type == KNIGHT


def _hook(board: CrazyhouseBoard, king: int, move: chess.Move, moved: int, pov: chess.Color) -> bool:
    if moved != ROOK or square_distance(move.to_square, king) != 1:
        return False
    for defender_square in board.attackers(pov, move.to_square):
        defender = board.piece_at(defender_square)
        if defender and defender.piece_type == KNIGHT and square_distance(defender_square, king) == 1:
            for pawn_square in board.attackers(pov, defender_square):
                pawn = board.piece_at(pawn_square)
                if pawn and pawn.piece_type == PAWN:
                    return True
    return False


def _arabian(board: CrazyhouseBoard, king: int, move: chess.Move, moved: int, pov: chess.Color) -> bool:
    if square_file(king) not in (0, 7) or square_rank(king) not in (0, 7):
        return False
    if moved != ROOK or square_distance(move.to_square, king) != 1:
        return False
    for knight_square in board.attackers(pov, move.to_square):
        knight = board.piece_at(knight_square)
        if (knight and knight.piece_type == KNIGHT
                and abs(square_rank(knight_square) - square_rank(king)) == 2
                and abs(square_file(knight_square) - square_file(king)) == 2):
            return True
    return False


def _boden_or_double_bishop(board: CrazyhouseBoard, king: int, pov: chess.Color) -> str | None:
    bishops = list(board.pieces(BISHOP, pov))
    if len(bishops) < 2:
        return None
    for square in chess.SQUARES:
        if square_distance(square, king) < 2:
            if not all(board.piece_type_at(s) == BISHOP for s in board.attackers(pov, square)):
                return None
    same_side = (square_file(bishops[0]) < square_file(king)) == (square_file(bishops[1]) > square_file(king))
    return "bodenMate" if same_side else "doubleBishopMate"


def _dovetail(board: CrazyhouseBoard, king: int, move: chess.Move, moved: int, pov: chess.Color) -> bool:
    if square_file(king) in (0, 7) or square_rank(king) in (0, 7):
        return False
    queen = move.to_square
    if (moved != QUEEN or square_file(queen) == square_file(king)
            or square_rank(queen) == square_rank(king) or square_distance(queen, king) > 1):
        return False
    for square in _ring(king):
        if square == queen:
            continue
        attackers = list(board.attackers(pov, square))
        if attackers == [queen]:
            if board.piece_at(square):
                return False
        elif attackers:
            return False
    return True
