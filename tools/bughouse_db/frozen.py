"""One bughouse board with its reserves frozen.

A puzzle is one board of a real game, considered alone: nothing arrives from
the partner, and a capture leaves for the partner rather than returning to
the capturer's hand. python-chess plays crazyhouse, which banks a capture in
the capturer's own pocket, so every move here is pushed through `frozen_push`
to put the pockets back as they were, less the piece a drop used.
"""

from __future__ import annotations

import chess
from chess.variant import CrazyhouseBoard


def frozen_push(board: CrazyhouseBoard, uci: str) -> str:
    """Play `uci` with the reserves frozen; return its SAN.

    A pawn drop is written `P@f7` as FICS and every player write it, not
    python-chess's bare `@f7`.
    """
    move = chess.Move.from_uci(uci)
    pockets = [board.pockets[chess.WHITE].copy(), board.pockets[chess.BLACK].copy()]
    mover = board.turn
    text = board.san(move)
    if text.startswith("@"):
        text = "P" + text
    board.push(move)
    board.pockets[chess.WHITE], board.pockets[chess.BLACK] = pockets
    if move.drop:
        board.pockets[mover].remove(move.drop)
    return text


def mating_moves(board: CrazyhouseBoard) -> list[str]:
    out = []
    for move in board.legal_moves:
        after = board.copy(stack=False)
        frozen_push(after, move.uci())
        if after.is_checkmate():
            out.append(move.uci())
    return out


def replay(fen: str, line: list[str]) -> list[CrazyhouseBoard]:
    """The boards along `line`: `boards[i]` is before ply `i`, `boards[-1]` after the last."""
    board = CrazyhouseBoard(fen)
    boards = [board.copy(stack=False)]
    for uci in line:
        frozen_push(board, uci)
        boards.append(board.copy(stack=False))
    return boards


def position_key(board: CrazyhouseBoard) -> str:
    """Placement, pockets, side to move, castling and en passant: what a repetition compares."""
    return " ".join(board.fen().split()[:4])
