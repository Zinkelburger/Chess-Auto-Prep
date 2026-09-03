"""A bughouse position: two crazyhouse boards that feed each other.

python-chess gives us crazyhouse — legal moves, drops, pockets, SAN — and
bughouse differs from it in exactly one rule, which is the rule that makes the
game:

    crazyhouse  you capture a black knight, it joins *your* reserve on *this*
                board as a white knight.
    bughouse    you hand it to your partner, who sits on the *other* board
                playing the opposite colour, and drops it as a *black* knight.

So the piece keeps its colour and changes board. Everything else — legality,
drops, promotion reverting to a pawn on capture — is crazyhouse, and is left
to python-chess rather than reimplemented.

Board A is where our team plays :attr:`DualBoard.team`; board B is where the
partner sits, playing the other colour. That mirrors the engine, which indexes
boards 1 and 2 and takes a single ``Team`` option.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import chess
from chess.variant import CrazyhouseBoard

BOARD_NAMES = ("A", "B")
START_FEN = CrazyhouseBoard.starting_fen


def san(board: CrazyhouseBoard, move: chess.Move) -> str:
    """SAN, with a pawn drop written `P@f7` rather than python-chess's `@f7`.

    Everyone else — FICS, the engine, every bughouse player — writes the piece
    letter on a drop, and a bare `@f7` reads as a typo.
    """
    text = board.san(move)
    return f"P{text}" if text.startswith("@") else text


def board_index(name: str | int) -> int:
    """The 0-based index of a board named the way a caller thinks of it.

    Boards are `A` and `B`; the engine calls the same two boards 1 and 2, so
    those digits are accepted as well, as a string or an integer. Nothing is
    0-based in the argument — internal code passes `BOARD_NAMES[i]` rather
    than the index, so `1` can only ever mean board A.
    """
    text = str(name).strip().upper()
    if text in ("A", "1"):
        return 0
    if text in ("B", "2"):
        return 1
    raise ValueError(f'Board must be "A" or "B" (or 1 or 2), not {name!r}.')


class IllegalMove(Exception):
    """A move that is not legal on the board it was addressed to."""


@dataclass
class Ply:
    """One half-move, tagged with the board it happened on.

    ``number`` is that board's own move number, so each board reads as an
    ordinary game — the way FICS recorded the two halves of a bughouse game as
    two separate games rather than one interleaved score.
    """

    board: str
    san: str
    uci: str
    number: int
    turn: str

    def as_dict(self) -> dict:
        return {
            "board": self.board,
            "number": self.number,
            "turn": self.turn,
            "san": self.san,
            "uci": self.uci,
        }


@dataclass
class DualBoard:
    """Two linked boards plus which colour our team plays on board A."""

    boards: list[CrazyhouseBoard] = field(
        default_factory=lambda: [CrazyhouseBoard(), CrazyhouseBoard()]
    )
    team: chess.Color = chess.WHITE
    history: list[Ply] = field(default_factory=list)

    # ── Construction ──────────────────────────────────────────────────────

    @classmethod
    def from_dual_fen(cls, dual_fen: str, team: chess.Color = chess.WHITE) -> "DualBoard":
        parts = [p.strip() for p in dual_fen.split("|")]
        if len(parts) == 1:
            parts.append(START_FEN)
        if len(parts) != 2:
            raise ValueError(
                'A dual FEN is two crazyhouse FENs separated by "|", '
                f"got {len(parts)} parts."
            )
        return cls(boards=[CrazyhouseBoard(p or START_FEN) for p in parts], team=team)

    def copy(self) -> "DualBoard":
        return DualBoard(
            boards=[b.copy(stack=False) for b in self.boards],
            team=self.team,
            history=list(self.history),
        )

    # ── Reading ───────────────────────────────────────────────────────────

    @property
    def dual_fen(self) -> str:
        return "|".join(b.fen() for b in self.boards)

    def board(self, which: str | int) -> CrazyhouseBoard:
        return self.boards[board_index(which)]

    def side_on(self, which: str | int) -> chess.Color:
        """The colour our team plays there: `team` on A, the other on B."""
        return self.team if board_index(which) == 0 else not self.team

    def our_turn_on(self, which: str | int) -> bool:
        return self.board(which).turn == self.side_on(which)

    def movetext(self, which: str | int) -> str:
        """One board's line as ordinary movetext — `1. e4 Nf6 2. e5 d5`."""
        name = BOARD_NAMES[board_index(which)]
        out: list[str] = []
        for ply in self.history:
            if ply.board != name:
                continue
            if ply.turn == "white":
                out.append(f"{ply.number}. {ply.san}")
            elif not out:
                out.append(f"{ply.number}... {ply.san}")
            else:
                out.append(ply.san)
        return " ".join(out)

    def pockets(self, which: str | int) -> dict[str, str]:
        b = self.board(which)
        return {
            "white": str(b.pockets[chess.WHITE]),
            "black": str(b.pockets[chess.BLACK]),
        }

    def describe(self) -> dict:
        return {
            "dual_fen": self.dual_fen,
            "team": "white" if self.team == chess.WHITE else "black",
            "boards": {
                name: {
                    "fen": self.board(name).fen(),
                    "turn": "white" if self.board(name).turn else "black",
                    "we_play": "white" if self.side_on(name) else "black",
                    "our_turn": self.our_turn_on(name),
                    "pockets": self.pockets(name),
                    "movetext": self.movetext(name),
                    "check": self.board(name).is_check(),
                    "over": self.board(name).is_game_over(),
                }
                for name in BOARD_NAMES
            },
        }

    # ── Playing ───────────────────────────────────────────────────────────

    def parse(self, which: str | int, text: str) -> chess.Move:
        """A move written as UCI (`e2e4`, `P@f7`) or SAN (`e4`, `P@f7`, `Nxf6+`)."""
        index = board_index(which)
        board = self.boards[index]
        text = text.strip()
        try:
            move = board.parse_uci(text)
        except ValueError:
            try:
                move = board.parse_san(text)
            except ValueError as e:
                raise IllegalMove(
                    f"{text!r} is not a legal move on board "
                    f"{BOARD_NAMES[index]} ({board.fen()}): {e}"
                ) from None
        if move not in board.legal_moves:
            raise IllegalMove(
                f"{text!r} is not legal on board "
                f"{BOARD_NAMES[index]} ({board.fen()})."
            )
        return move

    def push(self, which: str | int, text: str) -> Ply:
        """Plays one move and routes whatever it captures to the other board."""
        index = board_index(which)
        board = self.boards[index]
        move = self.parse(which, text)

        captured = self._captured_type(board, move)
        mover = board.turn
        number = board.fullmove_number
        text = san(board, move)
        board.push(move)

        if captured is not None:
            # Undo crazyhouse's own-pocket credit, then hand the piece to the
            # partner with its colour intact. That is the whole rule.
            board.pockets[mover].remove(captured)
            self.boards[1 - index].pockets[not mover].add(captured)

        ply = Ply(
            board=BOARD_NAMES[index],
            san=text,
            uci=move.uci(),
            number=number,
            turn="white" if mover else "black",
        )
        self.history.append(ply)
        return ply

    def push_line(self, moves: list[tuple[str | int, str]]) -> list[Ply]:
        return [self.push(which, text) for which, text in moves]

    @staticmethod
    def _captured_type(board: CrazyhouseBoard, move: chess.Move) -> int | None:
        """What this move takes, as the piece type that reaches a pocket.

        A promoted piece reverts to a pawn when captured; python-chess tracks
        which squares hold promoted pieces, so we ask it rather than guess.
        """
        if move.drop is not None:
            return None
        if board.is_en_passant(move):
            return chess.PAWN
        victim = board.piece_at(move.to_square)
        if victim is None:
            return None
        if board.promoted & chess.BB_SQUARES[move.to_square]:
            return chess.PAWN
        return victim.piece_type


def parse_move_list(moves: object) -> list[tuple[str, str]]:
    """Normalises the several shapes a caller may write a line in.

    Accepted, all meaning the same thing:

        "A:e4 A:Nf6 B:d4"                     one string
        ["A:e4", "A:Nf6", "B:d4"]             a list of tagged moves
        [["A", "e4"], ["A", "Nf6"]]           pairs
        [{"board": "A", "move": "e4"}, …]     objects

    A bare move with no board tag means board A, because a line of ordinary
    opening moves is the common case and writing `A:` before every one of them
    is noise.
    """
    if moves is None:
        return []
    if isinstance(moves, str):
        moves = moves.split()
    out: list[tuple[str, str]] = []
    for item in moves:
        if isinstance(item, str):
            board, _, text = item.partition(":")
            if not text:
                board, text = "A", board
            out.append((BOARD_NAMES[board_index(board)], text))
        elif isinstance(item, dict):
            board = item.get("board", "A")
            text = item.get("move") or item.get("san") or item.get("uci")
            if not text:
                raise ValueError(f"No move in {item!r}.")
            out.append((BOARD_NAMES[board_index(board)], str(text)))
        elif isinstance(item, (list, tuple)) and len(item) == 2:
            out.append((BOARD_NAMES[board_index(item[0])], str(item[1])))
        else:
            raise ValueError(f"Cannot read {item!r} as a move.")
    return out
