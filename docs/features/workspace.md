# The workspace

The board, move list, engine and explorer that every board mode shares. Whoever
is reading a game, building a repertoire, studying or drilling works here, and
leaves with a position on the board and, where the mode allows it, a move,
comment or annotation written into the document.

Code: `lib/workspace/` — `Workspace` (`workspace.dart`, the owners as one
value), `DocumentSession` (`document_session.dart`: the document, edits,
held edits, scratch analysis board; its cursor and comment lines in
`DocumentCursor`, `document_cursor.dart`), `WorkspaceView` (`workspace_view.dart`:
the board column and the reading card; `WorkspaceHooks` in
`workspace_hooks.dart`, the board column in `board_column.dart`, the
navigation row in `nav_row.dart`), `BoardView` (`board_view.dart`), `MoveTreeView` (`move_tree_view.dart`),
`MoveNote` (`move_note.dart`), `EngineAnalysis` / engine pane
(`engine_analysis.dart`, `engine_pane.dart`, `engine_settings.dart`),
`Explorer` (`explorer.dart`, `explorer_pane.dart`, `explorer_filters.dart`),
the explorer's Book source (`repertoire_tree.dart`, `tree_pane.dart`), pane
tabs and layout (`workspace_tabs.dart`, `action_layout.dart`,
`action_panes.dart`), `BoardEditor` (`board_editor.dart`), the move field
(`move_field.dart`, resolver `lib/chess/typed_move.dart`). Window wiring:
`lib/app/shell.dart`, `lib/app/top_bar.dart`, `lib/app/mode_view.dart`
(`ModeView`; each mode's view in its own file), `lib/app/save_held.dart`,
`lib/app/board_doors.dart`, `lib/app/train_doors.dart`, `lib/app/job_door.dart`,
`lib/app/document_tabs.dart`,
`lib/app/workspace_requests.dart`, `lib/app/layout_memory.dart`. Keys:
`lib/ui/app_keys.dart`. Architecture: [ARCHITECTURE](../ARCHITECTURE.md).

## Screen

Top to bottom, left to right:

- **Top bar** — `»` (only while the list column is hidden), Back / Forward
  (Alt+← / Alt+→; disabled when empty, the tooltip names the destination), the
  mode menu, `Actions` (Ctrl+K opens it as a typeable palette); the window's
  status sentence in the middle; the settings gear alone at the right end.
- **Document tabs** — one per open file or analysis board, with close buttons
  and a `+` that opens an empty analysis board. Closing the last one leaves an
  empty analysis board. Each tab keeps its place, held edits and undo.
  Each tab belongs to a mode, named first (`Viewer · Classic games`): the mode
  its document came up in, or the one a handoff (`Open in Builder`, a pasted
  board, `Open study`) sent it to. Going to a mode never renames a tab and never
  brings another mode's document along: the mode's own latest tab comes back at
  its game, move and held edits, and a mode with none gets the empty analysis
  board, which travels with the user rather than multiplying. Picking another
  mode's tab goes to that mode; closing a tab brings up the next one of the same
  mode. The builder and the trainer share their documents (one repertoire
  list); modes with a screen of their own leave the board as it is.
- **List column** (Ctrl+B hides it; `«` in its corner) — the mode's own list,
  or `Positions`, the searches' finds (Ctrl+P, Actions ▸ Panels ▸ `Positions`,
  or the list button on the Expectimax bar).
- **Board** — Lichess's chessground board: click-click or drag; only legal
  moves land; a pawn on the last rank waits for its piece. Coordinates are a
  setting (Settings ▸ Look). Selecting or dragging a piece tints its legal
  destinations as full squares, captures included; no dots or rings. The last
  move is highlighted. Right-drag draws an arrow, right-click a circle: green,
  Shift red, Alt blue, Ctrl yellow (Shift wins over Alt over Ctrl). Arrows use
  Lichess's geometry, a shaft a sixth of a square wide. The board shows the
  `[%cal]`/`[%csl]` shapes of the comment on the move under the cursor (the
  introduction's at the start), except over a comment's line or while part of
  the game is hidden. The engine's threat is a red arrow.
- **Under the board** — the move field (`Type a move`, `/` focuses it), the
  game counter where a mode has one, the engine pane, and the move note: the
  current move with its glyph and note (`14. Nf5!  Good move`), the game's
  introduction and first move (muted, clickable) at the start; fixed height, a
  long note scrolls; no card when there is nothing to say.
- **Engine pane** — a labelled sliding switch (`Engine`), the status
  (`Off`, `Starting…`, `Depth 24 · 12 MN/s · 345M nodes · Stockfish 19`,
  shortened to fit; no depth shown past 100), the threat crosshair (`Show
  threat` / `Hide threat`) and a gear (`Engine settings`: `Lines shown`, `CPU
  cores`, `Memory`, the same values as Settings ▸ Engine). Below, one fixed row
  per line: a score gutter (White's view, `+0.35`, `#5`) and the moves clipped
  to a row; a chevron (`Show full line`) opens it out. Resting on a move floats
  a 200 px board; clicking plays the line up to it. The pane keeps its height
  on, off, paused or showing settings, so the board never changes size; a
  quiet board (the viewer) keeps it blank until the engine is on, and a hidden
  puzzle answer keeps it blank too.
- **Reading card** — the pane tabs (`WorkspaceTab`: `Moves`, `Analysis`, `Game
  review`, `Solitaire`, `Train`, `Replies`, `Explorer`, `Expectimax`, `Audit`,
  `Puzzle`, `Game`, `Book`, `Filter`, `Player openings`, `My book`; each mode
  lists its own). Moves alone has no tab strip and no frame; the game or
  chapter heading is the top of the move text and scrolls with it.
- **Move list** (`Moves`) — read like a book: the main line as running text,
  each comment a paragraph under its move (laid out: paragraphs, headings,
  quotes, bare-FEN diagrams, inline moves that float a board on hover and play
  when they follow on), each variation an indented block after the move it
  replaces. Glyphs follow the SAN. The editing strip opens under it with Ctrl+E
  (see [pgn-viewer](pgn-viewer.md) for the held-edit strip).
- **Explorer** — a source row `Book | Masters | Lichess | TWIC | This file |
  My games` (one typeable `Database` box when narrow), `Filters` at its end for
  the chosen source's chips (folded by default; Lichess `Speed` and `Rating`,
  defaults Blitz/Rapid/Classical and 2000/2200/2500; TWIC `Classical OTB only`
  and `Download more`; none for Masters). One line names the board's opening
  (`C60 Ruy Lopez`, from the bundled lichess book by position; it keeps the
  last named one and is blank, same height, before the first). The table:
  `Move` (ticked when the chapter plays it), `Games` (count and share, `<1%`),
  `White / Draw / Black` bar, a `Σ` totals row; no rating column, no sorting.
  Under it, the games here (Masters 15, Lichess four top and four recent, TWIC
  12). `This file` and `My games` show `40 games` / `12 of 40 games`.
- **Explorer `Book`** — the book in use as an explorer (see
  [books](books.md)); `No book set.` without one. For the board's position,
  every move any chapter of the book for the board's side plays, matched by
  position: `Move` · `Lines` · `Goes on` · `Found in` (a click opens that
  file there). While it is up the board is free: a move the file does not play
  is shown, never written, and the header reads `Off the file: …` with a
  take-back and `Back to the file`; the engine follows the free board, while
  Replies, Expectimax and the other explorer sources stay on the file's
  position (they read `DocumentCursor.fen`, not `RepertoireTree.fen`).
- **Panes** — the pane's `+` (Tools) lists the mode's tabs, a few actions with
  their keys, `More room` / `Less room` (with several panes), `New pane`,
  `Close pane`, `Join all panes`. Up to four panes. Dragging a tab shows `Move
  here` / `Split right` / `Split below` targets; releasing elsewhere cancels.
  Right-click a tab (or Shift+F10) to close it (`Close tab`, also
  middle-click), move it to a named pane, split or join. A secondary pane's
  last tab closing closes the pane; when the main pane empties, the other
  pane's tabs come to it. Drag the gap between panes to resize. Ctrl+Tab /
  Ctrl+Shift+Tab / Ctrl+W walk and close the reading card's tabs.

## Actions

**Play a move** — board, move field, or an explorer row → an existing move
only moves the cursor; a new one at a branch point is added as the last
variation, with no notice even when it transposes. Where the document takes
edits it is written (builder and Study autosave; the viewer holds it).

**Type a move** — SAN or UCI in any case (`nf3`, `g1f3`, `0-0`, `e1h1`,
`e8=Q`, `e7e8q`, `N1f3`; marks and needless disambiguation optional) → played
the moment the words name one legal move that longer words could not turn into
another; Enter plays the one move left (a bare promotion is a queen); Esc
clears and gives the keys back; words no move is written as turn the box red.
In a drill, a move's first letter typed on the lesson goes to the field.

**Move menu** (right-click a move, Shift+F10) — `Promote variation`, `Make
main line`, `Delete from here` (no confirmation; Ctrl+Z restores), `Copy line
PGN`, `Copy FEN`, plus the mode's entries (e.g. `Add line to study…` in the
viewer).

**Edit a note or glyph** — Ctrl+E or Actions ▸ `Edit` opens the strip and the
pencil on the move note. The comment field edits the prose only; machine
tokens are re-attached after the prose on save, clearing the prose keeps them,
and a comment left empty is removed rather than written as `{}`. Undo is
Ctrl+Z.

**Draw shapes** — a drawing is written into the move's comment where the
document takes edits (builder, Study, the analysis board, the viewer while
editing); elsewhere it stays until the position changes. Drawn twice a shape
goes; another colour recolours it. A left click on the board takes the
comment's shapes out where edits are taken, else hides them until the
position changes; the threat stays.

**Engine** — the switch, E or Actions ▸ `Engine on` → starts or retries a
failed start; the engine is off at every launch. Changing cores or memory
restarts it; lines apply to the next search. Show threat (setting
`engineThreat`, off by default) runs a depth-12 search of the turn-passed
position just before the position's lines and draws its best move red; a
stopped search's answer is dropped. A paused engine (another job holds it)
or a failed start shows its reason in the status.

**Explorer** — pick a source → the table reloads and the choice is kept in
`settings.json` (the viewer starts on `This file` in its own explorer). A
row click plays the move. A listed game is fetched, kept as a file under
`pgn_collections/explorer games/` (an existing copy is opened as it is) and
opened in the PGN Viewer at the ply on the board; a `This file` game is put on
the board in place. Problems, each with one way out: `Could not reach the
Lichess database — it needs a connection.` (`… TWIC works offline.` when it is
there) with `Try again`; `Lichess is rate-limiting requests.`; `Log in to
Lichess to use the opening explorer. …` with `Log in to Lichess` and `Use
TWIC`; `Download the TWIC database to explore master games offline.` with
`Download TWIC database` (see [databases](databases.md)); `The classical
index for this database is not built. Turn off Classical OTB only to see all
games.`

**Analysis board** — a document no file holds (`DocumentSession.isScratch`,
`lib/chess/pgn/analysis_board.dart`): moves, variations, comments, glyphs and
undo work as on a chapter; the strip says `Not saved`. The document tab `+`
opens an empty one. Ctrl+V (`Paste PGN or FEN`) puts a pasted PGN (first
game, variations and comments kept), bare moves or a FEN on a new analysis
board from any mode, except that in the builder and trainer a PGN becomes a
repertoire (Actions ▸ `Paste PGN as repertoire`); Ctrl+Shift+V takes a FEN
only. A FEN may be quoted, a `[FEN "…"]` tag or cut short; one that cannot be
played says why (`Not a playable FEN. …`); `Nothing to paste: copy a PGN or
FEN first.` Ctrl+N / `Open Analysis tab` opens the `Analysis` tab: a scratch
copy of the whole current game at the cursor, facing the same way, that never
writes the source. While that tab is up, paste and set-up fill it instead. In
the builder `Save to repertoire…` and in Study `Save to study…` ask where,
then a chapter name. Closing the window forgets analysis boards.

**Set up position** — Ctrl+Shift+E or Actions ▸ `Set up position…` → the
board editor (`Set up a position`) on the board's position, same way up:
spare strips `[pointer] K Q R B N P [bin]` above and below (swap with the
flip); a spare dragged lands, clicked becomes a brush that paints every square
pressed or stroked; right-click empties a square. Beside it: side to move,
Start position, Clear board, Flip board, castling boxes (enabled only with
king and rook at home), en passant as `None` plus the candidates; under it the
FEN, which sets the board as soon as it reads (`Could not read that FEN.`).
An illegal setup names its reason while `Use this position` waits. The result
is a new analysis board. The same editor is embedded in Study's new-chapter
dialog and the tournament's position dialog.

**Full screen** — F11 or Actions ▸ Window ▸ `Full screen`, every mode.

**Layout** — panes, open tabs and board size are remembered per mode and
document in `settings.json` `workspaceLayouts`; Actions ▸ `Reset workspace
layout` restores the mode's default.

### Keys

Every binding is an `AppKey`: handlers bind it, tooltips name it and Settings ▸
Shortcuts lists it. Board: ←/→, Home/End (also PgUp/PgDn), Enter (into the
variation at the cursor), Esc (out of the variation, then the edit strip, then
a sitting), F flip, E engine, Ctrl+E edit, Ctrl+Z undo, Ctrl+S save, `/` move
field, Ctrl+Tab / Ctrl+Shift+Tab / Ctrl+W tabs. Window: Ctrl+K Actions, Ctrl+,
settings, Ctrl+B list, Ctrl+P Positions, Ctrl+O open, Ctrl+V / Ctrl+Shift+V
paste, Ctrl+N Analysis tab, Ctrl+Shift+E set up, Ctrl+G search from the board,
F11 full screen, Alt+← / Alt+→ history, Space play / show solution, ↑/↓ next or
previous game or puzzle. Trainer: Space, ↓, Esc, 1–4. Board-square keyboard
focus: arrows, Enter/Space, Esc. A text field with focus keeps its keys.

## Data

- **The document is the PGN.** A comment is kept whole in the tree so it
  round-trips byte for byte; only display strips `[%…]` tokens
  (`lib/chess/pgn/comment_text.dart`). A round trip must keep `[%eval]`,
  `[%pv]`, `[%clk]`, `[%cal]`/`[%csl]`, `[%tstart]`/`[%tend]`, the review
  markers and the app's generated metrics (`[%score]`, `[%expectimax]`,
  `[%cumProb]`).
- **Settings** are global across boards (`settings.json`): coordinates,
  figurines, engine choice, cores, memory, lines, threat, explorer source and
  chips, layouts. See [settings](settings.md).
- **Engine cache** — `<support>/eval_cache.db`, SQLite `evals(fen,
  eval_cp_white, depth, created_at)` keyed by the four-field FEN, White's view,
  deeper wins. Read and written by
  fixed-depth jobs (expectimax search and fill, chapter audit); the engine
  pane neither reads nor writes it.
- **Lichess explorer** — `explorer.lichess.org` with the saved token (it
  answers 401 without one); 15 s timeout, 100 ms minimum gap, 3 attempts; a
  429 shuts the door for 60 s, then doubling to 240 s, during which every
  position answers `Lichess is rate-limiting requests.` at once. Asked a
  quarter second after the cursor rests; not past ply 50, nor deeper after
  three empty answers in a row on a line. Answers cached in memory only (2000
  entries); nothing on disk.
- **Local sources** — TWIC reads `master_games.db` with no network; `This
  file` indexes the open file's main lines to ply 50 (`indexedPlies`) and
  lists 100 games; `My games` reads the downloaded games.
  Both are built once and answered from memory.
- **Book source** — files indexed once and re-parsed only when their bytes
  change; each chapter of a course file indexed from its own games; the open
  file read live.
- Builder, PGN Viewer, Study, Trainer and Tactics read and write through this,
  and share the engine with jobs (`EngineJobs`).

## Owner decisions

- Keep the UI clean: a new capability is a tab on the reading card or a source
  behind an existing tab, never a new dialog, dock or top-level control. A
  dialog asks one question and closes; more than three fields is wrong. Each
  tab owns at most one control at the strip's right edge; configuration lives
  behind it (owner, 2026-09-22).
- The explorer is a tab, as lila's book button swaps the move list for it; the
  sources are one segmented row with `Filters` at its end, folded and always
  labelled `Filters` (owner, 2026-09-22; 2026-10-01). Clicking a row plays the
  move; on a repertoire chapter playing saves, so there is no `Add to
  repertoire` (owner, 2026-09-22).
- Explorer columns are move, games and the bar; no average rating, no sorting
  (owner, 2026-09-22).
- The Lichess databases stay online-only with an in-memory cache. Offline the
  explorer says so, names TWIC when present, and offers `Try again`; never an
  empty table or an endless spinner.
- Transpositions are quiet, as on lila: a played move is added where the
  cursor is with no notice (owner, 2026-09-22).
- No eval bar anywhere; the score lives in the engine gutter (owner,
  2026-09-21). One move list for reading and editing.
- The engine pane is an inline bar under the board, not a headline
  above the tabs (owner, 2026-09-23: "ugly above all the tabs"). The board
  never changes size when the engine switches or opens its settings
  (2026-10-14).
- Legal destinations are subtle full-square tints, no dots or rings
  (owner, 2026-09-27).
- The top bar keeps Back / Forward, mode, Actions at the left in a fixed order
  and the settings gear alone at the right end; the mode menu lists modes only
  (owner, 2026-09-22). Colours follow [DESIGN.md](../../DESIGN.md).
- The list column holds the mode's list or `Positions`; another result set
  that wants the column becomes a second list there, not a mode or dialog
  (owner, 2026-09-23).
- A mode starts as one pane (the Repertoire builder as Moves beside
  Expectimax); a tool picked from `+` while there is one pane opens under it;
  the `+` menu offers `New pane` (owner, 2026-10-01).
- Expectimax and similar search values are never computed while the player
  browses; panes show stored values ([generation](generation.md)).
