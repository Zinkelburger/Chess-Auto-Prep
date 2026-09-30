# PGN Viewer

Status: corrected by the owner (2026-09-21, layout and editing decisions below)
Old code (oracle only): `lib/screens/pgn_viewer_screen*.dart`, `lib/features/documents/`, `lib/widgets/pgn/`
Plan step: 6

## Purpose
Someone opens a PGN — a downloaded collection, their own games, a course, a study chapter — to read
the games, check them against their repertoire and mark up what they found. They leave with the game
understood and, when they edited, the file saved or a copy written.

## Screen
Reached from the mode menu, and by handoff from Tactics/recent games ("Review"), Study, Engine
tournament games and position analysis. A handoff may name a file, a game, a ply, a position slice, the
tab to land on and whether to start the engine review at once. Screenshot: `img/pgn-viewer.png`.

- **Title button** — the open file's base name, `Open games` when nothing is open, `Pasted games` for
  pasted text. Its menu holds up to 10 recent files (current one checked and disabled, full path in the
  tooltip), `Browse for file…`, `Paste PGN from clipboard (Ctrl+V)` and `Close file — back to the start
  screen`.
- **Filter chips** plus `+ Filter games` — one chip per active criterion; hidden with no collection
  and when the viewer was opened for one named game. A `Back to filters` button replaces them after
  opening a game from the filter results, on the Game tab only.
- **`Actions` menu** (opens on hover), **mode switcher**, **settings gear**.
- **Board pane** (left) — shared board, see `workspace.md`; adds a red engine threat arrow and a
  yellow ring for a solitaire hint.
- **Game counter bar** under the board — `‹ Game [n] of N ›`, a type-to-jump number box, `Search`,
  play/pause, speed. Hidden with no visible game and while the opening tree owns the board.
- **Side panel tabs**, closeable, with fixed identities — `Game`, `My books`, `Database explorer`,
  `Evaluation graph`, `Tree`, `Collection`, `Filter`. Only `Game` is open at first; the whole bar is
  hidden during a solitaire session.
- **Deviation banner** (Game tab) — where the game left the designated book: `You left book: 12...Nf6
  (book 12...Bd7) · <chapter>`, `Not in book: …`, `Book ends after …`, or `Different opening — this game
  did not enter this book`, with `Show my line`. Amber for a deviation, neutral when book ran out.
- **Game tab** — optional engine bar (shared) and opening label, an edit/save strip while editing or
  when a save is pending, then the shared movetext reader (`workspace.md`). Reading is prose, not a
  grid: scrolling never moves the board, the move heading pins while its note is read, and a reviewed
  game prints no per-move score — only classified moves get an inset `Blunder +0.3 → +2.1`.
- **Empty states** — `No PGN loaded` with `Open PGN File` and a `Recent` list; `No games match the
  current filters` with `Show All Games`.
- **`My books` tab** — `Matching lines` / `Chapter contents`, a chapter picker, a line search and `Edit
  this chapter in the Repertoire Builder`. Empty: `Open a game to check it against your books.`
- **`Database explorer` tab** — shared explorer, see `workspace.md`.
- **`Evaluation graph` tab** — `Analyze Game`, the graph, and the list of blunders, mistakes,
  inaccuracies and interesting moves. A graph restored from stored evals offers `Re-analyze at depth
  {target}`; empty, `Load a PGN to analyze`.
- **`Tree` tab** — a `Collection` / `Database` source toggle, `Filter`, `Include variations`, the
  merged opening tree of the *visible* games with W/D/L bars, the games at the cursor, and
  `Building tree... {done} / {total} games` while it builds.
- **`Collection` tab** — `Opening tree`, `Export PGN…`, `Export Scid…` and `Save selection to study…`,
  all over the games in the current filter.
- **`Filter` tab** — positions (the current one, a board setup editor, or extra ones), a move sequence
  with a gap (default 4), and header rules on player names, ratings, date or any raw tag with the
  operators `contains`, `excludes`, `is`, `matches regex`, `at least`, `at most`; plus a `Combine`
  any/all toggle, a live `Check filters` count, `Clear filters` and `Apply filter`.
- **Fullscreen (F11)** — board, game label, counter, navigation and autoplay only; a 2px progress bar
  and a blocking spinner cover loading.

## Actions
**Open a file** — recent entry, `Browse for file…` (`.pgn`/`.txt`) or a handoff → the whole file is
decoded off the UI thread and held in memory (no cap, no paging), the saved filter and reading position
for that path are restored, the path joins the recent list (max 10) → for 5 s: `File not found:
<name>`, `Could not read <name>`, `File is empty: <name>`, `No valid PGN games in <name>`, `Could not
parse <name>`, `Could not open <name>: <error>`.
**Paste PGN** — Ctrl+V → a `Pasted games` collection, `Loaded N game(s) from clipboard` → `Clipboard
is empty — copy some PGN first`, `No valid PGN games found in the pasted text`, `Could not parse the
pasted PGN`.
**Close file** — drops the collection, leaves edit mode, returns to the Game tab and the start screen.
**Pick a game** — counter arrows, number box, `Search`, a tree node or a filter result → board, reader,
books check and graph follow; the reading position (game key + ply + sort) is remembered per file.
**Sort** — file order, newest first, rating high, rating low; ties keep file order. A handoff for one
named game silently sorts newest-first first.
**Filter** — the count recomputes 300 ms after the last keystroke and matching runs off the UI thread;
`Apply filter` narrows the visible games and saves the slice for that path → `Could not search these
games. Try again.` A restored slice says `Restored last slice (x/y games)` with `Show All`; one that
matches nothing is discarded silently.
**Edit / annotate** — `Edit` in Actions (disabled on the My books tab) → a panel targets the move the
board sits on: free text committed 400 ms after typing stops, plus six exclusive glyphs (`!!`, `!`,
`!?`, `?!`, `?`, `??`); other NAGs show but are not editable. Clearing the box never deletes a stored
comment (`Comment kept until deleted`); deleting asks `Delete 1 comment?`. `[%eval]`, `[%pv]` and
`[%clk]` are hidden from the box and re-attached ahead of the prose on save. A sideline's menu:
`Copy line PGN`, `Add line to study…`, `Comment`, `Delete variation`, `Clear all analysis`.
**Save** — autosave is on by default and writes 300 ms after an edit; it is blocked after any failed
write, copy failure, draft restore, reload or recovery, and then only explicit `Save` writes. That opens
`Save PGN collection` showing `No unsaved changes` / `Unsaved changes` / `Saving…` / `Saved`, or a
problem — `The file changed or was removed. Your draft is unchanged. Inspect the current file or save a
copy.`, `Could not save. Your draft is unchanged. You can retry or save a copy.`, `The file may have
been saved. Your draft is retained. Inspect and reload before saving again, or save a copy.`, `That
destination already exists. Nothing was replaced. Choose another name for your copy.` — with `Save`,
`Save a copy…`, `Keep editing`, `Inspect current file`, `Reload and keep draft`.
**Leave with unsaved work** — closing, opening another file or leaving the mode → the same dialog plus
`Close without saving` and `Cancel`; nothing is asked when there is nothing to resolve.
**Restart recovery** — a checkpoint is written 1 s after the workspace settles → after a crash, `PGN
work from a previous session is available.` with `Review recovery`; restoring opens the draft without
writing to the original.
**Compare against my books** — Actions or the banner → the My books tab loads the designated repertoire
for the guessed colour and shows the matching lines.
**Engine review** — `Analyze Game`, or a handoff's autoAnalyze → evaluates every mainline move, writes
`[%eval]` and a best line into the comments, draws the graph and marks the mistakes; progress reads
`Analyzing move {done} / {total}  (depth {d})` with `Stop analysis`. Results are adopted in place, so
the cursor and the reader's own scratch lines are untouched. Skipped when cached evals cover it.
**Solitaire chess** — Actions → a setup strip: `Guess for` White/Black (defaults to the side at the
bottom), `Game start` vs `From here`, `Include variations`, `Reveal after` 0–600 s in steps of 15
(default 60, hint at half that), and a live `N <side> moves to guess.` Enter begins, Escape cancels,
zero moves refuses. A wrong guess shows `Incorrect — try again` and is kept as a sideline; the reply
plays 400 ms later. Completion reads `Complete — 12/18 first try, 2 hinted, 1 revealed.` with `Exit
solitaire`, `Copy PGN`, `Add to study…`, `Analyse for trophies` and `Next game (↓)`. Its per-move
notes enter the movetext and travel with Copy PGN but are never written to the file. Switching game or
leaving asks `Switch game?` / `Leave solitaire?` — `Your guesses in this game so far are lost.`
Refused while the opening tree owns the board; after a review, guesses that beat the played move
become trophies (`Trophy earned — your <move> beat <move>.`).
**Copy / export** — `Copy Game PGN`, `Copy mainline PGN (no comments)`, `Copy FEN`; `Export as PGN…`
and `Export as SCID…` write every game in the current filter (Scid asks for a folder and a name →
`Scid export failed: <error>`); `Add to Study` / `Edit study` hands the games to Study.
**Autoplay** — Space or the counter bar → one move every 1.0 s by default (300 ms before the first;
speeds 0.5–10 s per move), optionally rolling into the next game; any navigation, game load, tab change
or panel close stops it. (v2, 2026-09-23: Space or Actions ▸ `Play through` at the fixed speed; any cursor move or
another game stops it; no speed setting, no roll into the next game yet.)
**Keyboard** — ←/→ a move, Home/End ends of line, ↑/↓ previous/next game, Enter focus variation, Escape
leave (innermost first), F flip, E engine, Space autoplay, F11 fullscreen, Ctrl+V paste.

## Data
- Reads and writes the opened `.pgn`/`.txt` in place as a per-game patch against the loaded baseline;
  untouched games are written back unchanged. Comments, variations, NAGs, headers and the machine
  tokens `[%eval]`, `[%pv]`, `[%clk]` must survive a round trip.
- Bundled and downloaded collections live in `Documents/pgn_collections/`; studies, repertoire
  chapters and analysis games open from their own folders and are the same files Study, Repertoires
  and Builder write.
- Per path: last file, up to 10 recent files, the saved filter, the reading session (game key, ply,
  sort). Restart checkpoints: `<app support>/pgn-viewer-recovery-v1/<id>.json`, one per running
  instance, leased so a live instance is not offered for recovery.
- Evals written into the comments are read back by the Tactics review and the graph; My books reads
  the designated repertoires; `Add to Study` writes into the Study library.

## Keep / Change / Drop
Keep — Title button
Keep — Filter chips
Keep — `Actions` menu
Keep — Board pane
Keep — Game counter bar
Keep — Side panel tabs
Keep — Deviation banner
Keep — Game tab
Keep — Empty states
Keep — `My books` tab
Keep — `Database explorer` tab
Keep — `Evaluation graph` tab
Keep — `Tree` tab
Keep — `Collection` tab
Keep — `Filter` tab
Keep — Fullscreen (F11)
Keep — Open a file
Keep — Paste PGN
Keep — Close file
Keep — Pick a game
Keep — Sort
Keep — Filter
Keep — Edit / annotate
Keep — Save
Keep — Leave with unsaved work
Keep — Restart recovery
Keep — Compare against my books
Keep — Engine review
Keep — Solitaire chess
Keep — Copy / export
Keep — Autoplay
Keep — Keyboard

Quirks to rule on: the viewer holds the whole PGN in memory with no size cap; autosave is on by
default and edits a file the user may only have meant to read; solitaire annotations show in the
movetext and ride along with Copy PGN but are deliberately not saved; `Tree` and `Database explorer`
reach the same explorer; the tab bar disappears entirely during solitaire.

## Owner decisions (2026-09-21)
- **Layout A**: the old app's shape — board with the typeable `‹ n of N ›` counter under it, one
  reading column (heading, engine row, moves, navigation row) — plus the game list in the left pane.
  The left pane has `+` beside its name to open a file; the `«` that hides it (Ctrl+B) is in the
  pane's own top right corner, and the `»` that brings it back is at the top bar's left.
- **The reading column is half the workspace** (owner, same day: "text default to 50% of the
  screen, shrink the board to compensate") and is drawn as the old app's near-black rounded card,
  moves in mono 16 with the old line height, the words inset 24 px from the card's edge. What the
  owner missed from the old viewer was this card, not a brighter type colour: the old ink was
  `#F2F2F2` on `#000000`, v2's is `#E6E6E8` on a flat `#1B1B1D` everywhere.
- **Reading shows no editing chrome.** Editing is a strip under the moves, opened from Actions ▸ Edit
  or Ctrl+E: Done, Undo, the save state, the six glyphs and the comment field. Right-click ▸ Comment
  is the second way in (not built yet). Save trouble shows the strip on its own.
- **No eval bar anywhere in the app.** The engine pane is one row when off.
- **Comments are laid out**: paragraphs, inline moves, bare-FEN diagrams, Chessable headings and
  quotes. Hovering an inline move shows a small board. Clicking one that follows on from the move
  shows that position on the main board and marks the move, without writing anything to the file.
  ←/→ step through the line, and Esc or any move in the file goes back to the file. If the file
  already has those moves, the cursor just goes there.
- **One Actions menu** in the top bar, the same shape whatever mode opened the document, with Ctrl+K
  as a typeable palette over the same list.
- **Solitaire is an action of the viewer**, not a mode. **A file outside Documents is copied into
  `pgn_collections` on open** (default on; a setting later). Autosave was kept here; superseded
  on 2026-09-23 (below). Scid export and paging remain open questions.
- **`Tree` and `Database explorer` are one `Explorer` tab** of the reading card (owner, 2026-09-22;
  `workspace.md`). The old `Tree` tab's merged opening tree of the open file is the `This file`
  source in the tab's source row, beside `My games`, `Masters`, `Lichess` and `TWIC`; the old app's
  own note that both tabs "reach the same explorer" is taken at its word. `Collection` and
  `Filter` are unchanged by this.

## Owner decisions (2026-09-22, evening)
- **A file with chapters lists its games under them**, as the builder reads it: a Lichess study
  export by `ChapterName`, a course by the player header its chapters are titled in (the rule in
  `chess/pgn/chapter_grouping.dart`, shared with the repertoire import). A chapter heading shows
  its name and `N games` and folds; the chapter holding the game on the board opens and stays open
  when the board leaves it, so the rows never move under the pointer. A chapter of one game is
  that game's row. Under a chapter a course line is called by its own title (`Najdorf`, not
  `Sicilian – Najdorf`). Search temporarily unfolds matching chapters, including ones folded by
  hand, and matching a chapter name includes its games. Clearing search restores manual folds. The field follows the
  query when a file is reopened, and flat and grouped rows share one cached selection. Widgets are
  constructed only for the viewport. A plain collection stays the flat list.
- **The start of a game names its first move.** The note under the board shows the game's
  introduction, then the first move muted with its note; clicking it plays it, as → does. Hidden
  while a line is being found (puzzles, training).

## Built for step 6c (2026-09-23, not yet seen by the owner)
- **`This file`** in the Explorer tab's source row is the old `Tree` tab: the main lines of the open
  file's games to move 25, merged by position so move orders meet, each move with its games and
  White / draw / Black (a game without a result counts as played but draws no bar), the first 100
  games under the moves. It follows the viewer's filter without building again; a file past 64 KiB
  is built on another isolate that opening another file, pasting onto the board or closing kills.
  Any changed game list invalidates the old index before its replacement is built: equal game counts
  do not mean the same game numbers. Filter results belong to that same list of games.
  The row's end reads `40 games` / `12 of 40 games`. A listed game is put on the board in place,
  where its own main line reaches the position. Not built: `Include variations`, the tree's own
  cursor and back button.
- **`My games`** is every game of the user's on this machine, each once: the downloads in
  `games_library/` and, read only from the old app's `app_games.db`, the same accounts' library and
  Player analysis collections and the tactics archive. A database that cannot be read leaves the
  downloads and says so beside the table. A listed game is kept as a file and opened, as TWIC's.
- **Filters** are `Filter games` under the search box, not a tab: folded, the applied rules as chips
  that remove them and `n of N`; unfolded, a Field / Rule / Value block per rule (typeable choice
  fields suggesting the file's headers and values), `Add rule`, `All` / `Any`, `Clear`. Rules are
  the old header rules (`contains`, `excludes`, `is`, `regex`, `≥`, `≤`, `Player` on either
  colour, `;` between names) and apply 300 ms after typing rests; another file clears them.
  Regex filters always run in a cancellable worker; literal filters also do so for 500 or more games or at least 64 KiB of headers. A worker has a 2-second deadline.
  The list shows `Filtering games…` while waiting and a problem if the work times out or fails;
  changing or clearing the rules recovers. Cancelled or superseded results never replace the current
  selection. Position filtering and per-file restoration were added below, move sequences on 2026-09-28. Not built: multiple position conditions and `Check filters`.

## Owner decisions (2026-09-23)

- **Edits in the viewer are not saved until the user saves them.** Moves played on the board,
  notes and glyphs are shown at once but held in memory (`DocumentSession.holdsEdits`, on while the
  viewer is up). The edit strip then shows `Unsaved changes` with `Discard` and `Save` (Ctrl+S; also
  in the Actions menu); Ctrl+Z takes held edits back one at a time (the latest 100 steps). History
  shares immutable document versions rather than keeping a full PGN string per step; Discard still restores the
  original document after older undo steps have been dropped. Save, including Ctrl+S while typing,
  commits the active comment field before writing. Document tabs retain viewer
  drafts and undo while another file or analysis is up; selecting the original tab
  restores them against the original save revision. Reloading or closing its tab
  discards the held edits. Once an edit is held, later edits join it in every
  mode until it is saved or discarded. The builder and Study keep autosaving.
- **A read-only file holds moves too** (owner, 2026-09-27). A file outside
  Documents that was not copied on open takes moves, notes and glyphs in the
  viewer like any other; the strip says `Unsaved changes · this file is
  read-only`, and Save (Ctrl+S, or Save changes in Actions) asks where they
  go: `Copy into Documents…` writes the game with them into `pgn_collections`
  and opens that copy, `Add to a study…` makes them a new study chapter. The
  standing read-only notice stays hidden while the viewer holds edits.
- **No colour for the unsaved state**, and **no snackbars anywhere in v2**: deletions say nothing
  (Ctrl+Z undoes them), and a failure goes to the status bar under the top bar, which has a Close
  button and, when there is a way out, one action such as Reload.

## Built 2026-09-27

- Compact document tabs have left-aligned labels, close buttons, drag ordering
  and no click splash. Pane (tool) tabs have no close button since 2026-09-28:
  right-click → Close tab or middle-click closes one, and closing a secondary
  pane's last tab closes that pane. A tab dropped on another pane's tab row
  (on a tab or its empty end) moves there. The pane's plus menu reopens closed tools.
- **Analysis beside Moves and Explorer** contains a scratch copy of the complete
  current game, variations and comments at the current move, and starts the
  engine. Open it from the inner strip's plus menu, Actions → Show Analysis, or
  Ctrl+N. The collection, filters and file tab stay in place; analysis moves and
  pasted PGN/FEN never write the source. Each game's scratch analysis and undo
  history survive switching inner tabs and collections for this window.
  Choosing another game returns to Moves. File tabs retain their appearance;
  inner tabs have square lower edges and join the reading card.
- Flip board stays in Actions; no duplicated top-bar buttons. The viewer opens
  with Moves, Explorer and Game review, omits repertoire actions and the chapter-editing
  sidebar, and only offers Save/Discard after edits exist. The outer strip's
  plus opens an independent empty scratch document.


- File-order, date and rating sorting preserve original game indices. The list,
  grouped chapters, counter, number entry and arrow keys use the same visible
  selection. Unknown ratings sort last; equal keys retain file order.
- `Export visible games as PGN…` captures the selected draft and ordering before
  its name/directory dialogs. Exclusive publication refuses existing files;
  original PGNs are unchanged. Inline comment editors commit into the snapshot.
- The existing `pgn_viewer.session:<path>` preference now restores game identity,
  cursor and sort. v2 additionally keeps variation path/FEN and header-filter
  rules. Reordered games are found by canonical identity; a missing game does
  not redirect the bookmark to an unrelated index. An explicit game handoff
  overrides the saved place. A restored header slice matching nothing clears.
  Checkpoints coalesce per path and survive owner disposal; failed writes remain
  retryable and visible. No PGN is written by reading-state changes.

- **Filter games → Reaching this position** captures the board position once.
  It searches complete main lines (including custom starting positions and moves
  beyond the opening tree's depth), matching transpositions while ignoring move
  counters and respecting side to move, castling rights and en passant. It
  intersects with the existing all/any header conditions. The removable position
  chip previews the captured board on hover; Clear all restores the collection.
  Matching runs in a cancellable worker with a 15-second deadline. Selecting a
  matching game lands at its first occurrence of the position. The position is
  remembered with the file's reading state.
- **Export matching games…** beside filtered results uses the existing exclusive
  PGN export. It snapshots complete visible games, in the selected sort order,
  including their comments and variations. It is disabled during filtering,
  after a filtering failure, or with no results. Source files are unchanged.

## Current review and editing controls (2026-09-27)

The **Game review** tab (since 2026-09-28) is the old viewer's graph only — no
second move list: an **Analyze game** button, an **Annotate PGN** switch, the
evaluation graph (winning-chances scale, White light above / Black dark below,
?! / ? / ?? dots in blue / amber / red; hover reads the move, click or drag goes
to it) and per-side mark counts with ACPL (a count steps through those moves).
The annotations are read in Moves: coloured glyphs, a "Mistake. Nf3 was best."
note and the engine's line as a variation. A depth-14 Stockfish pass evaluates
the main line, adds `[%eval]` values, conservative loss glyphs (50/100/200 cp for
inaccuracy/mistake/blunder) and up to eight plies of the suggested alternative at
classified moves. Existing comments, clocks, glyphs and variations are retained.
An `[%eval]` the file already had is kept, not replaced. Everything the review
writes is marked (`[%cap_review_eval]`, `[%cap_review_nag N]`,
`[%cap_review_line N]` with the line's move count), so turning **Annotate PGN**
off removes exactly that and leaves the game as the file had it. A review line
the user played on or wrote in is theirs: removing or re-running the review
takes only its marker out. Turning the switch on again puts the last review
back without re-running it, as long as the main line is still the one it
reviewed, and while it is off the next review only draws the graph. Read-only
files show the graph and write nothing.
The graph also reads evaluations already stored in a PGN. Values are White's
perspective; they are engine assessments, not calibrated win probabilities.

Review is one undoable Viewer edit, held for Save/Discard. It never writes the
source automatically. Stop, an edit, another game or another document cancels the
run and rejects late results. A failed or cancelled run leaves the game unchanged;
partial progress is not published. Review currently covers the main line at fixed
depth 14; it does not recursively review existing variations.

The note beneath the board has a pencil for editing in place (Ctrl+E); Builder
uses the same editor open by default. The Viewer Actions menu omits duplicate
open/close, panel controls, full-screen controls and Save a copy entries.
File selection stays in the collection area, panel selection in the tab strip,
and export stays with filtering as well as its explicit export command. Recovery
and Save dialogs still offer Save a copy when needed. Independent scratch
**Analysis** remains distinct from whole-game review.

## Game buttons and solitaire (2026-09-28)

The owner could not find editing, analysis or solitaire in the v2 viewer. A
game's heading now has three outlined buttons under it: **Edit** (Ctrl+E,
`Done editing` while the strip is open), **Analyze game** (opens Game review
and starts it; `Stop analysis · n/N` while running) and **Solitaire**. The
Actions menu lists the same three (`Edit`, `Analyze game`, `Solitaire chess`).
Edit and Analyze are off while a solitaire game is being guessed; Solitaire is
off while a review runs.

**Solitaire** is a `Solitaire` tab of the viewer (`workspace/solitaire.dart`,
`solitaire_pane.dart`). The setup asks `Guess for` White/Black (default: the
side at the bottom) and `Start at` Move 1 / This move, and counts the moves to
guess. While guessing, the game is shown only up to the move being guessed
(`DocumentSession.showOnlyTo`), so the move list, note, keys and the review
graph cannot give it away; the engine is switched off. A board move is judged
against the main line: right advances and the other side's reply plays 400 ms
later; wrong says `Not the game move. Try again.` and writes nothing. `Hint`
names the piece, `Show move` plays it. The end reads `Complete — 12/18 first
try, 2 hinted, 1 shown` with `Play again`, `Next game`, `Done` and a clickable
list of missed moves with what was tried. Esc, another game or leaving the
mode ends it. Solitaire never writes the file. Not built from the old
viewer: the reveal timer, sideline guessing, keeping wrong guesses as
variations, and trophies.

## Opening names (2026-09-28)

A viewed game's heading has a third line, its opening (`B90 Sicilian Defense:
Najdorf Variation`), from the bundled lichess book `assets/data/openings/`
matched by position, so transpositions find the name (`chess/openings.dart`).
It names the last named position on the way to the cursor, lila-style; before
the first one it shows the game's own `ECO` / `Opening` / `Variation` tags,
else the last named position of the main line (not while a puzzle answer is
hidden). The line is there for every game, empty without a name, so moving
through the game never moves what is under it. The book is read once, the
first time a name is wanted, and parsed off the UI isolate; a book that
cannot be read is logged and shows no names. The Explorer tab names the
board's position the same way over its table (see `workspace.md`).

## Parity with the old viewer (2026-09-28)

- **My books** is a viewer tab (open it from the pane's plus menu or Show
  my line): what the book in use says about the game on the board, read
  from the side the board is seen from (flip to check the other side's
  book) — the same check, words and panel as My games (`BoardBook`,
  `workspace/book_verdict_view.dart`). A game that left the book gets one
  line under its heading, `You left book: 3...Nf6 (book 3...cxd4) · Main`,
  with `Show my line`, which opens My books at that move. Nothing is said
  for a game in book, another opening or no book in use.
- **Add to study** is one picker (chapter name when one chapter goes in,
  `New study…`, typeable study list) and one command from everywhere:
  Actions ▸ `Add game to study…` and `Save selection to study…`, `Save to
  study…` beside filtered results, `Add line to study…` on a move's menu
  (the moves to the end of that line), Tactics ▸ `Add game to study…`,
  solitaire's `Add to study…`, the analysis board and a read-only file's
  Save. The mode stays; the status bar says where the chapters went, with
  `Open study`. A study open in the workspace takes them through its editor;
  any other is appended on disk through the store, touching no other game.
- **Moves** in Filter games takes a move sequence: move numbers optional,
  `…` (or `...`, `[gap]`) for "anywhere after". `contains`, `excludes`,
  `is` and `starts with` read the main line, `regex` the moves written out,
  `≥` / `≤` count its moves. It runs in the filter worker (15 s deadline);
  a game opened from the results lands after the sequence. Header rules
  gained `starts with`. The old gap limit (at most N plies) is not built:
  a gap means any number of plies.
- **Follow a player**: a file most of whose games (four in five) have one
  player shows each game from that player's side. `Follow a player` under
  the sort box suggests the file's names, most games first, and follows one
  once it is picked or entered with Enter, never while it is typed; Enter
  on a cleared box follows nobody. Kept per file with the reading place; a
  flip on a game stands until the next game.
- **Unsaved edits after a crash**: held edits are checkpointed a second
  after they settle to `Support/viewer-drafts/` (one write per burst,
  encoded off the UI isolate) and dropped once saved or discarded on the
  visit that made them; leaving or hiding the window writes the pending
  checkpoint at once, closing it writes it before it goes and asks when one
  could not be written, and a tab closed on held edits closes only once
  their checkpoint is written (otherwise it stays open and the bar says
  why). Opening the file
  again — after a restart, or after closing its tab on held edits — says
  `Unsaved edits to <file> from an earlier session.` (without the last
  words in the same run) with `Restore unsaved edits`, which holds them
  against the revision they were made on. When the file changed since,
  the line adds `The file has changed since.` and offers `Save them as a
  copy` (`<file> unsaved edits.pgn` beside it) instead. A checkpoint
  edited past without restoring, or one that cannot be read, is moved into
  the recovery quarantine.
