# PGN Viewer

The player opens a PGN — a downloaded collection, their own games, a course, a
game the explorer or a database handed over — to read it like a book, check it
against their books, review it with the engine or replay it as solitaire. They
leave with the game understood and, only if they chose to save, the file or a
copy written.

Code: `lib/features/pgn_viewer/` (`PgnViewer` owner, `PgnViewerPanel` list
column, `ViewerFilterPane`, `ViewerReading`, `AutoPlay`, `PlayerSideChoice`,
`export_dialog.dart`), mode wiring `ViewerView` in `lib/app/document_views.dart`
and `WorkspaceRequests.openFile` / `browse` in `lib/app/workspace_requests.dart`.
Shared owners: `DocumentSession` (`lib/workspace/document_session.dart`), the
filter `FileFilter` (`lib/workspace/file_filter.dart`, rules in
`lib/chess/game_filter.dart`), `GameReview` (`lib/workspace/game_review.dart`),
`Solitaire` (`lib/workspace/solitaire.dart`), `DraftKeeper`
(`lib/workspace/draft_keeper.dart`), storage `lib/storage/viewer_places.dart`,
`viewer_drafts.dart`, `recent_pgn_files.dart`, `pgn_file_store.dart`. Board,
move list, engine and explorer are described in [workspace](workspace.md).

## Screen

- **List column** (left; Ctrl+B or the `«` in its corner hides it) — the open
  file's name with a `+` (`Open PGN file…`, Ctrl+O), a `Search` box, a filter
  button (`Filter games`) and, while a filter narrows, `n of N` (`Filtering…`
  while it runs) with `Clear`; an `Order` field (`File order`, `Newest first`,
  `Rating high`, `Rating low`; typeable) and `Follow a player`. Then the games:
  number, players, result; the game on the board is marked. A file with
  chapters (Lichess `ChapterName`, a course's player-header titles; rule in
  `chess/pgn/chapter_grouping.dart`) lists games under folding chapter
  headings with `N games`; a one-game chapter is that game's row, called by
  the chapter. In a followed player's collection a row shows a light or dark
  disc for their colour and the opponent's name. Nothing open: `Recent files`
  (name, folder from home down) or `No PGN open. Open a file to read its
  games.` with `Open PGN file…`. Empty list messages: `No games in this
  file.`, `Nothing matches "<query>".`, `No games match the filter.`,
  `Filtering games…`.
- **Board** with the game counter under it — `‹ [n] of N ›`, the number
  typeable to jump. On Read the board is quiet: the engine row appears only
  while the engine is on (E), the move field while typed in (`/`), the
  move-note card when the move has a note. On Edit the engine row and the move
  field are always there.
- **Reading card** — opens on `Moves` alone: no tab strip, no frame, a `+` in
  its corner. The game's heading (players, result · event · year, opening
  name) is the top of the move text and scrolls with it. Where the game left
  the user's book, one line under the heading says so, e.g. `You left book:
  3...Nf6 (book 3...cxd4) · Main`, with `Show my line`. Its foot is `Read |
  Edit` (Ctrl+E), then the four move arrows; the viewer opens on Read.
- **`+` menu** — the viewer's tabs (`Moves`, `Explorer`, `Filter`, `Analysis`,
  `Game review`, `Solitaire`, `My books`), then `Engine on` with its key, then
  `New pane`. A tab picked while Moves is alone opens under it.
- **Tabs** — `Explorer` starts on `This file` here (other modes keep their
  remembered source); for a followed player it offers `All n` / `White n` /
  `Black n`. `Filter`, `Analysis` (a scratch copy of the whole game at the
  cursor, engine on; Ctrl+N), `Game review`, `Solitaire`, `My books` (what the
  book in use says about the game, from the side the board is seen from).
- **Edit strip** (under the moves on Edit, or while edits are held) — Undo,
  the save state (`Saved`, `Unsaved changes`, `Unsaved changes · this file is
  read-only`, `Edits stay unsaved until you save them`), `Discard` and `Save`
  while edits are held, then on Edit the glyphs and the comment field. `Read`
  closes it; there is no `Done`.
- **Actions menu** (Ctrl+K) — Document: `Edit` / `Done editing`, `Undo`,
  `Save changes` and `Discard changes` while edits are held; Board: `Flip
  board`, `Engine on`/`off`, `Play through` / `Stop playing`; Game: `Analyze
  game` / `Stop analysis`, `Analyze all games` (the review's `Analyze all N
  games`), `Solitaire chess` / `Stop
  solitaire`, `Add game to study…`; File: `Open in Study` (a study's file),
  `Close file`, `Filter games`, `Export visible games as PGN…`, `Save
  selection to study…`; Copy: `Copy game PGN`, `Copy FEN`.

## Actions

**Open a file** — `+`, Ctrl+O, a recent entry, or a handoff (explorer game,
Databases, Study, Tactics, Engine tournament) → the file becomes the
workspace document with its first (or the named) game on the board, and goes
to the top of the recent list (10 kept). A file outside Documents is copied
into `Documents/pgn_collections/` first when `Copy files from outside
Documents when opened` is on (default); `Could not copy <name> into your
Documents: <detail>` otherwise. With copying off, or for a file whose
encoding is not UTF-8, it opens read-only. The saved reading place for that
path (game, cursor, variation, sort, filter rules, followed player) is
restored unless the handoff names a game.

**Pick a game** — click a row, ↑/↓, the counter's arrows or number → the game
goes on the board without re-reading the file; the list, grouped chapters,
counter and arrow keys walk the same visible order. Sort ties keep file order;
unknown ratings sort last.

**Search and filter** — the `Search` box narrows rows by the row's title (players),
result, event line and chapter name (a matching chapter brings its games; matching chapters unfold
while searching and restore manual folds when cleared). The `Filter` tab
holds rules: `Field` (`Player`, `Moves`, `White`, `Black`, `White rating`,
`Black rating`, `Date`, `Event`, `Site`, `Result`, `ECO`, `Opening`, or any
header typed) / `Rule` (`contains`, `excludes`, `is`, `starts with`, `regex`,
`≥`, `≤`) / `Value`, `Add rule`, `Reaching this position`, `All` / `Any`,
`Clear`, and while narrowing `Export matching games…` and `Save to study…`.
`Player` matches either colour, `;` separates names. `Moves` takes a
sequence, move numbers optional, `…` / `...` / `[gap]` for "anywhere after";
`≥`/`≤` count its moves. `Reaching this position` captures the board once and
matches transpositions on complete main lines (side to move, castling and en
passant count; move counters do not); its chip previews the board on hover.
Typing applies 300 ms after it rests. Regex, position and move rules always run
in a cancellable worker, as do other rules from 500 games or 64 KiB of
headers; the deadline is 2 s for header rules and 15 s for moves and
positions. A timeout or failure is shown in the list; changing or clearing
the rules recovers; late results never replace the current list. A game
opened from a move or position result lands where it matched. Another file
starts with its own saved rules.

**Follow a player** — a file where one player has at least four games in five
follows them automatically; `Follow a player` suggests the file's names (most
games first) and follows the one picked or entered, never one half typed;
Enter on an empty box follows nobody. Each game turns to that player's side;
a manual flip stands until the next game.

**Read and edit** — the viewer and Study share this card and its rule.
`Read | Edit` at the card's foot, Ctrl+E or Actions ▸ `Edit` turns it; each
mode keeps its own side (the viewer starts on Read, Study on Edit). On Read,
moves played, review annotations and the like show at once but are held in
memory (`DocumentSession.holdsEdits`): the strip says `Unsaved changes` with
`Discard` (asks `Discard unsaved changes?`) and `Save` / Ctrl+S. On Edit every
change is written as it is made, as in the builder, and turning to Edit writes
what Read held first; Ctrl+Z undoes either way (100 steps held). Coming to the
mode, or to a document tab that held edits, never writes them. A read-only
file holds edits on Read and Edit alike, and Save asks `Save your moves` →
`Copy into Documents…` (a name, then a copy in `pgn_collections` that opens)
or `Add to a study…`. Document tabs keep each file's held edits and undo
while another is up. Failures go to the top bar's status line with one way
out (`Retry save`, Reload).

**Open in Study** — a file from `Documents/studies` read here goes to Study
on the same chapter; Study's `Read in PGN Viewer` comes back.

**Unsaved edits after a crash** — held edits are checkpointed about a second
after they settle (one write per burst, encoded off the UI isolate); leaving or
hiding the window writes a pending checkpoint at once, and a tab closed on
held edits closes only once its checkpoint is written. Opening the file again
says `Unsaved edits to <file> from an earlier session.` with `Restore unsaved
edits`; if the file changed since, `… The file has changed since.` with `Save
them as a copy` (`<file> unsaved edits.pgn` beside it). A checkpoint edited
past or unreadable is moved to the recovery quarantine.

**Game review** — `Analyze game` (Actions or the tab's button; `Stop` while
running) → a depth-14 Stockfish pass over the main line: an evaluation graph
(White above, Black below; ?!/?/?? dots; hover reads, click or drag goes to a
move), per-side mark counts and `ACPL` (each evaluation held within ±1000
first, as Lichess counts it). Moves are judged as Lichess judges them: by the
winning chances the side gave away (`2 / (1 + e^(-0.00368208·cp)) − 1`), 0.1
an inaccuracy, 0.2 a mistake, 0.3 a blunder; a forced mate appearing against
the mover is `Checkmate is now unavoidable` and one slipping away `Lost forced
checkmate sequence`, an inaccuracy, mistake or blunder by what was left
(beyond ±999, ±700, else). A move the engine itself chose is never marked.
With `Annotate PGN` on (the default) it also writes `[%eval]` values, the
glyph (never over the user's own), a `Mistake. Nf3 was best.` note in
Lichess's words and up to eight plies of the better line as a variation.
Every addition is marked (`[%cap_review_eval]`, `[%cap_review_nag N]`,
`[%cap_review_line N]`) so turning `Annotate PGN` off removes exactly that; an
existing `[%eval]` is kept; a review line the user played on or wrote in
becomes theirs. The review is one undoable edit, held on Read and written at
once on Edit. Stop, an edit or another game cancels it and drops late results.
`Analyze all N games` (a file of several games, `Annotate PGN` on, games
without a review) reviews each such game in turn, `Game 2 of 5 · 19 / 34
positions`, writing each into its own game as it ends (one undoable edit per
game); moving between the games goes on while it runs, Stop or another file
ends it, and a game whose main line changed meanwhile is left as it is.
Read-only files get the graph only (`This file is read-only`). The graph also
reads evaluations already in the PGN. One rule marks a move for the graph,
the counts and the annotations; a review read back from the file shows the
marks it wrote.

**Solitaire** — `Solitaire chess` → the Solitaire tab: `Guess for` White /
Black (default: the side at the bottom), `Start at` `Beginning` / `Current
position`, `N <side> moves to guess.`, `Start solitaire`. Play follows the main
line; the reply comes 400 ms later; the board faces the guessing side. `Hint`
names the piece (counts as assisted); `Give up this move` reveals it. A private
engine (`lib/engines/solitaire_evaluator.dart`) checks five candidates at depth
14; another move counts when it is within 50 cp of the game move from the
guesser's side (mates by outcome and distance), and a better one earns
`Better move!`. If the check cannot finish, the player retries, plays the game
move or gives up; an unjudged move is never called a mistake. Future moves,
notes and variations stay hidden (`DocumentSession.showOnlyTo`) and visible
engine analysis is off. At the end the full game returns with attempts, hints
and evaluations annotated: `Copy session PGN`, `Play again`, `Next game`,
`Add to study…`, `Done`. Esc, another game or leaving the mode ends it.
Solitaire never writes the source file.

**Play through** — Space or `Play through` → one main-line move a second
(first after 300 ms); stops at the end or at any cursor move, edit or other
game.

**Add to study** — `Add game to study…`, `Save selection to study…`, `Save to
study…` in Filter, `Add line to study…` on a move's menu, solitaire's `Add to
study…` → one study picker (chapter name for a single chapter, `New study…`,
typeable list). The mode stays; the status line names where the chapters went
with `Open study`.

**Export** — `Export visible games as PGN…` / `Export matching games…` →
`Export visible games` asks a `PGN file name`, then `Choose folder` → the
visible games in list order, with comments and variations, written to a new
file; an existing file is never replaced; the source is untouched. Refused
while filtering: `Wait for filtering to finish and select at least one game.`

**Close file** — Actions ▸ `Close file` → back to the recent list.

Keys: ←/→, Home/End, ↑/↓ (game), Enter/Esc (variation), F, E, Space, Ctrl+E
(edit), Ctrl+S, Ctrl+Z, Ctrl+N (Analysis tab), Ctrl+O, Ctrl+B, F11 — all from
`AppKey`.

## Data

- **The file** — read whole and held as the session's document; a save writes
  the edited games back through the guarded document store against the
  revision it was read at (a changed file is a conflict, never an overwrite).
  Comments, variations, NAGs, headers and machine tokens (`[%eval]`, `[%pv]`,
  `[%clk]`, `[%cal]`/`[%csl]`, review markers) must survive a round trip.
- **Writable only inside Documents** — files outside it (or not UTF-8) open
  read-only (`pgn_file_store.dart`); copies go to
  `Documents/pgn_collections/`; explorer games are kept under
  `pgn_collections/explorer games/`, Databases games under `database games/`.
- **Reading place** — SharedPreferences `pgn_viewer.session:<path>` (game
  identity, cursor, variation path/FEN, sort, filter rules, followed player);
  written only by reading changes, never touching the PGN. A reordered file
  finds the game by identity; a missing game does not redirect to another.
- **Recent files** — up to 10 paths in SharedPreferences
  (`pgn_viewer_recent_files`).
- **Held-edit checkpoints** — one JSON per document under
  `<support>/viewer-drafts/`, naming the revision the edits were made on;
  removed when saved or discarded.
- **Layout** — panes, open tabs and board size are remembered per mode and
  file in `settings.json` `workspaceLayouts` (`lib/app/layout_memory.dart`);
  Actions ▸ `Reset workspace layout` restores the default.
- Evaluations written by a review are read back by the graph and Tactics;
  `My books` reads the book in use ([books](books.md)); Add to study writes
  through the Study store.

## Owner decisions

- Layout: board with the typeable `‹ n of N ›` counter under it, one reading
  column, the game list in the left pane (owner, 2026-09-21). The reading
  column defaults to half the workspace, drawn as a near-black rounded card
  with moves in mono 16 (owner, 2026-09-21).
- No eval bar anywhere in the app (owner, 2026-09-21).
- Reading shows no editing chrome; editing is the strip, opened by `Read |
  Edit` at the card's foot, Ctrl+E or Actions ▸ Edit (owner, 2026-09-21,
  2026-10-24).
- Comments are laid out: paragraphs, inline moves (hover shows a board; click
  shows the position without writing), bare-FEN diagrams, headings and quotes
  (owner, 2026-09-21).
- Solitaire is an action of the viewer, not a mode (owner, 2026-09-21).
- A file outside Documents is copied into `pgn_collections` on open, default
  on, with a setting (owner, 2026-09-21).
- One `Explorer` tab; the file's own tree is its `This file` source (owner,
  2026-09-22).
- A file with chapters lists its games under them; the chapter holding the
  board's game opens and stays open so rows never move under the pointer
  (owner, 2026-09-22).
- The viewer and Study are one card, as alike as they can be: on Read edits
  are held until saved, on Edit they autosave, and the two modes differ only
  in their list and which side of the switch they open on (owner,
  2026-10-24: "unify them as much as possible"). A
  read-only file holds edits on both sides and Save asks where they go
  (owner, 2026-09-27).
- Mistakes are marked by lost winning chances, as Lichess marks them, and
  `Annotate PGN` is on by default (owner, 2026-10-24).
- No colour for the unsaved state and no snackbars: failures go to the top
  bar's status line with one action (owner, 2026-09-23).
- A file opens as a book: moves alone, no engine, no extra buttons until used
  (owner, 2026-10-01: "sometimes I just want to view a PGN like a book").
  `Filter` is a tab (owner, 2026-10-01).
