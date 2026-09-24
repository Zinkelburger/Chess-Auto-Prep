# My games

Status: built 2026-09-22 at the owner's request ("its own view… to have the user check what they
played compared to their book"); not yet corrected by the owner
Old code (oracle only): `lib/features/games/services/game_deviation_service.dart`,
`lib/features/games/services/opening_review.dart`, `lib/features/games/widgets/game_card.dart`,
`lib/features/games/widgets/repertoire_line_panel.dart`
Plan step: 9c

## Purpose
Someone who has repertoires and plays online opens this to see where their games left their book:
their own moves the book does not play, opponents' moves the book has no answer for, and places
the book ran out. They leave knowing which lines to fix, one click from the file that holds them.

## Screen
Reached from the mode menu (`My games`, after Tactics). Games left, board in the middle, reading
card right; the card's tabs are `Book` (pinned), `Game` and `Explorer`
(whose `Book` source shows what else the book plays). The book chip (`books.md`) sits under the
accounts; with no book in use the list says `No book set. Pick the book to compare your games with.`

- **Accounts block** — the same block as the top of the Tactics column: the usernames with
  `Change`, `Get games` / `Pause` / `Resume` and its status line. With no username, only
  `Add accounts`.
- **Games | Openings** — a two-way switch over the rest of the column.
- **Games** — a `Search by opponent, date or move` box, `12 games, newest first` (`2 of 12 games`
  while searching), then one row per game: `vs rival (2105) · Won · 2026.09.22` over the move and
  a short verdict — `6.f3 left book`, `7.Nf3 not in book`, `5.d3 book ended`, `in book to the end`,
  `another opening`, `no Black book`. The game on the board is highlighted.
- **Openings** — the games that left the book, grouped by the same move at the same position (or the
  same place the book ended), most games first, under `You left book (n)`, `Not in your book (n)`
  and `Book ended (n)`. A row reads `6.f3 · 3 games` over `Book 6.Be3 · Sicilian`.
- **Book tab** — the verdict in full (`You left book: 6.f3 (book 6.Be3)`) over `vs rival (2089) ·
  Won · 2026.09.22`; `Played` and the move; `Your book` and each move it plays there with its line
  count, how the fullest file goes on and that file's name; `Show the move` and `Open in builder`.
- **Empty states** — `Reading your games and repertoires…`, `No games saved yet. Get games above to
  download them.`, `Nothing matches "q".`, `None of these games left your book.`, and on the Book tab
  `Open one of your games from the list to compare it with your book.`
- **Board** — the game from the user's side; no game counter under it.

## Actions
**Get games** — the Tactics download and review (see `tactics.md`). While fewer than 200 of an
account's games are saved, a download asks for 200; after that for the review's 20.
**Check** — opening the mode, or a download or a repertoire change while it is open → the newest
200 saved games of each account are read against the chapters of the book in use for the side the
user played, the same chapters the explorer's `Book` reads. A game is in the book up to the last of its positions
any of those files reaches, by any move order, so a transposition counts and a game that leaves
and comes back is judged from where it last left. Fewer than two plies in the book is `another
opening`, not a deviation. The move played from that last position is the verdict.
**Open a game** — a row → the game on the board, flipped to the user's side, at the move that left
the book (at the book's last move when it ended). ↑/↓ walk the list as the search leaves it, newest first.
**Open a group** — an Openings row → its newest game, the same way.
**Show the move** — back to that moment after walking the game.
**Open in builder** — the file with the most lines through the position, in Repertoire builder, at
that position. Clicking a book move's file opens it after that move.

## Data
- Read only. Games: `Documents/games_library/{site}_{username}.pgn` (the old app's cache, written by
  the Tactics download). Repertoires: `Documents/repertoires/**`, drafts left out. Usernames: the
  old app's preference keys.
- Nothing is written; the verdicts are worked out again each time the mode opens.

## Keep / Change / Drop
Keep — Accounts block
Keep — Games | Openings
Keep — Games
Keep — Openings
Keep — Book tab
Keep — Get games
Keep — Check
Keep — Open a game
Keep — Open a group
Keep — Show the move
Keep — Open in builder

Not built from the old app: the Stockfish mistake counts and the moments strip on each game, the
game-card board thumbnails, per-book verdicts when several files disagree, commentary lines marked
"not recommended". A download is not windowed by time control.

## Questions for the owner
- Should the mistake counts and the moments strip come here from Tactics?
- Is 200 games per account the right window?
