"""The explorer's position key, and why it is a *position* key.

The tempting key for a two-board game is the move sequence, because BPGN
hands you one.  Measured on the 2017 archive (105k games), that key is dead
by ply 6: only 14% of games still sit in a node with 10+ games, because the
interleaving of the two boards multiplies the branching factor.  Keying on
the *position* instead merges every interleaving that reaches the same
place, and buys about five plies -- which is the difference between a toy
and an opening explorer.

The key is FNV-1a over the canonical dual FEN, exactly mirroring
`lib/services/master_games/position_key.dart` so Dart and Python agree
without a shared Zobrist table.  Canonical means each board truncated to
four FEN fields (placement-with-pocket, turn, castling, en passant): the
half-move and full-move counters are path, not position.

Not done here, and deliberately: board A and board B could be swapped (and
the result flipped with them, since relabelling the boards swaps the teams)
to merge each node with its mirror and buy roughly one more ply.  It is a
real lever, left off in v1 because it has to be undone consistently on read
or the explorer shows moves on the wrong board.
"""

from __future__ import annotations

_FNV_OFFSET = 0xCBF29CE484222325
_FNV_PRIME = 0x100000001B3
_MASK64 = (1 << 64) - 1


def canonical_fen4(fen: str) -> str:
    """`fen` truncated to its first four space-separated fields."""
    parts = fen.split(" ")
    return " ".join(parts[:4])


def dual_key_fen(fen_a: str, fen_b: str) -> str:
    """The canonical dual FEN that [position_key] hashes."""
    return f"{canonical_fen4(fen_a)} | {canonical_fen4(fen_b)}"


def position_key(dual_fen: str) -> int:
    """Signed 64-bit FNV-1a of `dual_fen`, matching Dart's `positionKey`."""
    h = _FNV_OFFSET
    for byte in dual_fen.encode("utf-8"):
        h = ((h ^ byte) * _FNV_PRIME) & _MASK64
    return h - (1 << 64) if h >= (1 << 63) else h
