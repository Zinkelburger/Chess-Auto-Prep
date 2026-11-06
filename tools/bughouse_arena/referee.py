"""Bughouse rules for the arena: two crazyhouse boards whose captures feed the
partner, judged by the same terminal rules the engine searches with.

The referee is deliberately an independent implementation (python-chess, not
Fairy-Stockfish) so a rules bug in either side shows up as a disagreement
instead of being shared silently. Every rule that decides a result mirrors
Hivemind's ``engine/src/environment/board.cc`` (unpack
``tools/bughouse_windows/hivemind-source.tar.gz`` to read it):

* ``is_checkmate(team, time_advantage)`` ports ``Board::is_checkmate`` and
  ``Board::can_partner_provide_blocking_piece``, so a check that the partner can
  still feed a blocker for is not mate, and a team with no legal move anywhere
  it is on turn loses unless it is up on time.
* Draws are the engine's: fifty moves or threefold repetition of the on-board
  position (pockets ignored) on either board.

Teams use the engine's names. Team WHITE plays white on board A and black on
board B; team BLACK plays the other two seats.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass

import chess
from chess.variant import CrazyhouseBoard

BOARD_A = 0
BOARD_B = 1
BOARDS = (BOARD_A, BOARD_B)

STARTING_FEN = CrazyhouseBoard.starting_fen


def team_color(team: chess.Color, board: int) -> chess.Color:
    """The colour ``team`` plays on ``board``."""
    return team if board == BOARD_A else not team


def seat_team(board: int, color: chess.Color) -> chess.Color:
    """The team that owns the seat playing ``color`` on ``board``."""
    return color if board == BOARD_A else not color


def team_name(team: chess.Color) -> str:
    return "white" if team == chess.WHITE else "black"


class IllegalMove(ValueError):
    pass


@dataclass(frozen=True)
class PlayedMove:
    board: int
    uci: str

    def engine_token(self) -> str:
        """The engine's ``position ... moves`` spelling: board digit + UCI."""
        return f"{self.board + 1}{self.uci}"


class Bughouse:
    """Two linked crazyhouse boards plus the history the rules need."""

    def __init__(self, fen_a: str = STARTING_FEN, fen_b: str = STARTING_FEN):
        self.boards = [CrazyhouseBoard(fen_a.strip()),
                       CrazyhouseBoard(fen_b.strip())]
        self.start_fens = (self.boards[0].fen(), self.boards[1].fen())
        self.moves: list[PlayedMove] = []
        self._repetitions = [Counter(), Counter()]
        for board in BOARDS:
            self._repetitions[board][self._board_key(board)] += 1

    @classmethod
    def from_dual_fen(cls, dual_fen: str) -> "Bughouse":
        if dual_fen.count("|") != 1:
            raise ValueError(f"dual FEN needs exactly one '|': {dual_fen!r}")
        fen_a, fen_b = dual_fen.split("|")
        return cls(fen_a, fen_b)

    def copy(self) -> "Bughouse":
        clone = Bughouse.__new__(Bughouse)
        clone.boards = [self.boards[0].copy(), self.boards[1].copy()]
        clone.start_fens = self.start_fens
        clone.moves = list(self.moves)
        clone._repetitions = [Counter(self._repetitions[0]),
                              Counter(self._repetitions[1])]
        return clone

    # ------------------------------------------------------------------ state

    def turn(self, board: int) -> chess.Color:
        return self.boards[board].turn

    def on_turn(self, team: chess.Color, board: int) -> bool:
        return self.boards[board].turn == team_color(team, board)

    def seat_to_move(self, board: int) -> tuple[int, chess.Color]:
        return board, self.boards[board].turn

    def legal_moves(self, board: int) -> list[str]:
        return [move.uci() for move in self.boards[board].legal_moves]

    def has_legal_move(self, board: int) -> bool:
        return any(True for _ in self.boards[board].legal_moves)

    def is_legal(self, board: int, uci: str) -> bool:
        try:
            move = chess.Move.from_uci(uci)
        except ValueError:
            return False
        return move in self.boards[board].legal_moves

    def dual_fen(self) -> str:
        return f"{self.boards[0].fen()}|{self.boards[1].fen()}"

    def engine_moves(self) -> list[str]:
        return [move.engine_token() for move in self.moves]

    # ------------------------------------------------------------------- moves

    @staticmethod
    def _captured_type(position: CrazyhouseBoard, move: chess.Move) -> chess.PieceType | None:
        """What a move sends to the partner: promoted pieces go back as pawns."""
        if move.drop is not None:
            return None
        if position.is_en_passant(move):
            return chess.PAWN
        captured = position.piece_type_at(move.to_square)
        if captured is None:
            return None
        if position.promoted & chess.BB_SQUARES[move.to_square]:
            return chess.PAWN
        return captured

    def push(self, board: int, uci: str) -> None:
        position = self.boards[board]
        try:
            move = chess.Move.from_uci(uci)
        except ValueError as error:
            raise IllegalMove(f"board {board + 1}: unparsable move {uci!r}") from error
        if move not in position.legal_moves:
            raise IllegalMove(
                f"board {board + 1}: illegal move {uci!r} in {position.fen()}")
        mover = position.turn
        captured = self._captured_type(position, move)
        position.push(move)
        if captured is not None:
            # python-chess plays crazyhouse and pockets the capture for the
            # mover. In bughouse it belongs to the mover's partner, who plays
            # the opposite colour on the other board.
            position.pockets[mover].remove(captured)
            self.boards[1 - board].pockets[not mover].add(captured)
        self.moves.append(PlayedMove(board, move.uci()))
        self._repetitions[board][self._board_key(board)] += 1

    # ------------------------------------------------------------------- rules

    def _board_key(self, board: int) -> tuple:
        position = self.boards[board]
        ep = position.ep_square if position.has_legal_en_passant() else None
        return (position.board_fen(promoted=True), position.turn,
                position.castling_rights, ep)

    def is_draw(self) -> bool:
        for board in BOARDS:
            if self.boards[board].halfmove_clock >= 100:
                return True
            if self._repetitions[board][self._board_key(board)] >= 3:
                return True
        return False

    def is_checkmate(self, team: chess.Color, time_advantage: bool) -> bool:
        """Port of ``Board::is_checkmate`` (Hivemind engine/src/environment/board.cc)."""
        on_a = self.on_turn(team, BOARD_A)
        on_b = self.on_turn(team, BOARD_B)
        legal = {}

        def has_legal(board: int) -> bool:
            if board not in legal:
                legal[board] = self.has_legal_move(board)
            return legal[board]

        for board, on in ((BOARD_A, on_a), (BOARD_B, on_b)):
            position = self.boards[board]
            if on and position.is_check() and not has_legal(board):
                if not self._partner_can_provide_blocker(
                        board, position.turn, time_advantage):
                    return True

        if on_a or on_b:
            moves_on_a = on_a and has_legal(BOARD_A)
            moves_on_b = on_b and has_legal(BOARD_B)
            if (not moves_on_a and not moves_on_b
                    and (not time_advantage or (on_a and on_b))):
                return True
        return False

    def _partner_can_provide_blocker(self, board_in_check: int,
                                     checked_side: chess.Color,
                                     time_advantage: bool) -> bool:
        """Port of ``Board::can_partner_provide_blocking_piece``."""
        partner_board = 1 - board_in_check
        partner_side = not checked_side
        partner = self.boards[partner_board]
        is_partner_turn = partner.turn == partner_side

        if not is_partner_turn and not time_advantage:
            return False

        checked = self.boards[board_in_check]
        king = checked.king(checked_side)
        checkers = checked.checkers_mask()
        if chess.popcount(checkers) > 1:
            return False
        checker = chess.lsb(checkers)
        blocking = chess.between(king, checker)
        if not blocking:
            return False
        available = blocking & ~checked.occupied
        if not available:
            return False
        pawn_valid = available & ~(chess.BB_RANK_1 | chess.BB_RANK_8)

        def has_useful_capture(position: CrazyhouseBoard) -> bool:
            for move in position.legal_moves:
                captured = self._captured_type(position, move)
                if captured is None:
                    continue
                if captured == chess.PAWN:
                    if pawn_valid:
                        return True
                else:
                    return True
            return False

        if is_partner_turn:
            return has_useful_capture(partner)

        # Up on time the checked team may wait, but the opponent picks the
        # intervening move: a blocker is guaranteed only if every reply still
        # leaves the partner a useful capture.
        replies = list(partner.legal_moves)
        if not replies:
            return False
        for reply in replies:
            partner.push(reply)
            try:
                if not has_useful_capture(partner):
                    return False
            finally:
                partner.pop()
        return True
