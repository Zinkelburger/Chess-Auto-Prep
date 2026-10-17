# My games

A player who has repertoires and plays online opens this to see where their
own games left their book: their moves the book does not play, opponents'
moves the book has no answer for, and places the book ran out. They leave
knowing which lines to fix, one click from the file that holds them. Saved
games stay browsable and searchable with no book chosen.

Code: `lib/features/my_games/` (`MyGamesPanel`, `BookPane`, owner `GameBook`,
copy in `book_words.dart`), composed by `MyGamesView` in
`lib/app/training_views.dart`. It reuses the Tactics accounts block and
download (`lib/features/tactics/my_games_block.dart`, `MyGames`, passed in by
the shell), the pure check `lib/chess/book/book_check.dart`, the verdict panel
`lib/workspace/book_verdict_view.dart` (shared with the PGN Viewer's `My
books` tab), the repertoire index `lib/workspace/repertoire_shelf.dart`, the
book chip `lib/workspace/book_chip.dart` and the games cache
`lib/storage/my_games_files.dart`.

## Screen

Reached from the mode menu (`My games`, after `Tactics`). Games column left,
board middle, reading card right. No game counter under the board; ↑/↓ walk
the list instead.

- **Accounts block** — the same block as Tactics, worded `Add your Lichess or
  Chess.com username to browse and review your games.` when empty: usernames
  with `Change`, the `Bullet` / `Blitz` / `Rapid` / `Classical` chips, `Get
  games` / `Pause` / `Resume` and its status line (see [Tactics](tactics.md)).
- **Book chip** — the opening book in use ([Books](books.md)); switch or edit
  it from here.
- **Games | Openings** — a two-way switch over the rest of the column.
- **Games** — `Search by opponent, date or move`, `{n} games, newest first`
  (`{shown} of {n} games` while searching), then one row per game: `vs rival
  (2105) · Won · 2026.09.22` with the Tactics review's counts at the right
  (`1?? 2?`, `clean`; tooltip in words; nothing when the review has not seen
  the game), over the verdict tag — `6.f3 left book`, `7.Nf3 not in book`,
  `5.d3 book ended`, `in book to the end`, `another opening`, `no Black in
  book`. The game on the board is highlighted.
- **Openings** — games that left the book grouped by the same move at the
  same position (or the same place the book ended), most games first, under
  `You left book (n)`, `Not in your book (n)` and `Book ended (n)`. A row
  reads `6.f3 · 3 games` over `Book 6.Be3 · {file}` (`after 5.d3` over the
  file for a book that ended). With no book: `Choose a book above to compare
  openings. Your saved games are in Games.`
- **Card tabs** — `Game` (pinned: the moves), `Book` and `Game review` open by
  default, `Explorer` when opened.
- **Book tab** — the verdict in full (`You left book: 6.f3 (book 6.Be3)`,
  `Not in your book: 7.Nf3`, `Book ended after 5.d3`, `In book to the end`,
  `Another opening`, `Your book has no Black chapters`) over the game line;
  then `Played` and the move, `Your book` with each move the book plays there,
  its line count, how the fullest file goes on and that file's name; `Show
  the move` and `Open in builder`.
- **Messages** — `Reading your games and repertoires…`; `No games saved yet.
  Get games above to download them.`; `Nothing matches "{q}".`; `None of these
  games left your book.`; `Could not compare your games.` with `Try again`; on
  the Book tab `Open one of your games from the list to compare it with your
  book.`

## Actions

**Get games** — the Tactics download and review, unchanged (see
[Tactics](tactics.md)): 200 games are asked for while fewer than 200 of an
account's games are saved, else 20. Actions: `Get my games` / `Pause the
review`, `My accounts…`.

**Check** — showing the column or Book tab, a download, a username change, a
time-control change, another book in use or a repertoire file written → the
newest 200 saved games of each account, of the chosen time controls, are read
against the non-draft chapters of the book in use for the side the user
played. A later read overtakes an earlier one. A game is in the book up to
the *last* of its positions any chapter reaches, by any move order, so a
transposition counts and a game that leaves and comes back is judged from
where it last left. Fewer than two plies in the book is `another opening`,
not a deviation. The move played from that last position is the verdict.

**Open a game** — a row → the saved game on the board from the user's side,
at the move that left the book (after the book's last move when it ended).
↑/↓ walk the list as the search leaves it, newest first.

**Open a group** — an Openings row → its newest game, the same way.

**Show the move** — back to that moment after walking the game.

**Open in builder** — the file with the most lines through the position, in
Repertoire builder at that position. Clicking a book move's file name (`Open
{file} here`) opens it after that move.

## Data

- Reads `Documents/games_library/{site}_{username}.pgn` (written by the
  Tactics download), the repertoires through `RepertoireShelf` (drafts left
  out), the book in use from Books, the usernames (`lichess_username`,
  `chesscom_username` preferences), `myGameSpeeds` from settings, and the
  per-game counts from the `; ChessAutoPrep-Mistakes-v1: ` heading of
  `Documents/tactics_sets/Default.pgn` via `TacticsSet.mistakes`.
- Verdicts are not stored; they are worked out again on each read. A game
  opened on the board is an ordinary document of the games cache, so edits
  made there save into that file.

- How a game is compared (`chess/book/book_check.dart`): the book is a set
  of positions, so a game is in book while it reaches a position any book line
  reaches by any move order, and is judged from the last fork it never
  returned to. Measured on 2026-09-05 (7,537 games against four course
  exports): a move-prefix walk reported "left book at move 1–2" for 12% of
  White games, 15% against 1.d4 and 45% against 1.c4 that in fact left and
  re-entered the book 6–10 plies deeper. The first move pair must match
  (`bookEntryPlies`) before a game counts as in the book. Two hundred games
  per account is where an opening leak starts to repeat; twenty gave one game
  per entry.

## Owner decisions

- 2026-09-22: the book check is its own mode ("its own view… to have the user
  check what they played compared to their book"), not a block inside
  Tactics.
- 2026-09-23: games are read against the one opening book in use app-wide
  (Books), shown and switched with the book chip wherever a book is read. The
  default is no book, not every repertoire.
