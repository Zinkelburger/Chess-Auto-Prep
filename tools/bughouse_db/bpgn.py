"""Reading FICS bughouse games in BPGN, the format bughouse-db.org publishes.

A BPGN record is a PGN-shaped tag block followed by a movetext in which the
two boards are *interleaved in real time order*:

    1A. e4{596.000} 1B. e4{595.000} 1a. e5{598.000} 1b. e5{598.000}

The move number is per board and per side, the letter names the board, and
its case names the mover -- `1A.` is board A's White, `1a.` is board A's
Black.  That interleaving is the whole point of the format: it records when
each half-move actually happened, which is what makes a faithful two-board
replay possible at all.

Two properties of the real files bite a naive parser, and both are load-
bearing here:

  * they are CRLF, and
  * they are Latin-1, not UTF-8 -- FICS let players put arbitrary 8-bit
    bytes in handles, so `bytes.decode()` raises on the real archive.

Games are yielded from a stream rather than a whole-file read: the larger
years are ~900 MB uncompressed, and the indexer feeds this straight from
`bz2.open` so the expanded corpus never has to touch disk.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# `1A. e4`, `12b. N@f3`, `9A. bxa8=Q`.  The SAN is everything up to the
# clock brace or the next space; drops (`@`) and promotions ride along.
MOVE_RE = re.compile(r"(\d+)([AaBb])\.\s*([^\s{]+)")
TAG_RE = re.compile(r'\[([A-Za-z0-9_]+)\s+"([^"]*)"\]')
COMMENT_RE = re.compile(r"\{[^}]*\}")

ELO_TAGS = ("WhiteAElo", "BlackAElo", "WhiteBElo", "BlackBElo")
PLAYER_TAGS = ("WhiteA", "BlackA", "WhiteB", "BlackB")


@dataclass(slots=True)
class BpgnGame:
    """One bughouse game: its tags, and its half-moves in the order played."""

    tags: dict[str, str] = field(default_factory=dict)
    #: `(board, san)` in real time order.  `board` keeps BPGN's case, so it
    #: carries the mover as well as the board: `A`/`a`, `B`/`b`.
    moves: list[tuple[str, str]] = field(default_factory=list)

    @property
    def game_no(self) -> int:
        """bughouse-db.org's own id, which doubles as a permalink."""
        try:
            return int(self.tags.get("BughouseDBGameNo", "0"))
        except ValueError:
            return 0

    @property
    def result(self) -> str:
        """`1-0` (the team of WhiteA won), `0-1`, `1/2-1/2`, or `*`.

        Bughouse teams sit crosswise -- WhiteA partners BlackB -- so a `1-0`
        is a win for the *pair* WhiteA + BlackB, not for a player.
        """
        return self.tags.get("Result", "*")

    @property
    def year(self) -> int:
        date = self.tags.get("Date", "")
        try:
            return int(date.split(".")[0])
        except (ValueError, IndexError):
            return 0

    @property
    def rated(self) -> bool:
        return "unrated" not in self.tags.get("Event", "")

    def elos(self) -> list[int]:
        out = []
        for tag in ELO_TAGS:
            try:
                out.append(int(self.tags.get(tag, "0")))
            except ValueError:
                out.append(0)
        return out

    @property
    def avg_elo(self) -> int:
        """Mean of the four players' ratings; 0 when nobody is rated.

        Guest accounts carry Elo 0, so a game with guests in it averages
        down -- which is the honest signal, since a guest pair is exactly
        the game you do not want in an opening book.
        """
        return sum(self.elos()) // 4


def _build(tags: dict[str, str], movetext: str) -> BpgnGame:
    cleaned = COMMENT_RE.sub(" ", movetext)
    moves = [(board, san) for _, board, san in MOVE_RE.findall(cleaned)]
    return BpgnGame(tags=tags, moves=moves)


def iter_games(lines):
    """Yield a [BpgnGame] per record from an iterable of decoded lines."""
    tags: dict[str, str] = {}
    movetext: list[str] = []
    started = False
    for raw in lines:
        line = raw.rstrip("\r\n")
        if line.startswith("[Event "):
            if started:
                yield _build(tags, " ".join(movetext))
            tags, movetext, started = {}, [], True
        if not started:
            continue
        if line.startswith("["):
            tags.update(TAG_RE.findall(line))
        elif line:
            movetext.append(line)
    if started:
        yield _build(tags, " ".join(movetext))


def open_bpgn(path):
    """Open a `.bpgn` or `.bpgn.bz2` as a stream of Latin-1 text lines."""
    import bz2
    import io

    if str(path).endswith(".bz2"):
        return io.TextIOWrapper(bz2.open(path, "rb"), encoding="latin-1")
    return open(path, "r", encoding="latin-1")
