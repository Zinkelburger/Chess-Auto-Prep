# Repertoire builder

The mode where the user keeps and builds their opening repertoires: every
repertoire folder, its chapters, the lines of the open chapter, and the tools
that show what the chapter still lacks (Replies, Expectimax, Audit). A
repertoire chapter open here is editable, and every move played on it is saved.
The user leaves with a chapter that answers more of what opponents actually
play.

Code: `lib/features/library/` (the `Library` owner, `LibraryPanel`,
`OutlinePanel`, `ChapterOutline`, line transfers, deleted chapters, version
history, PGN drop), wired by `RepertoiresView` in `lib/app/document_views.dart` and
the outline column in `lib/app/shell.dart` and `lib/app/window_columns.dart`. Shared owners: `DocumentSession`
and `DocumentSaver` (`lib/workspace/`), the Replies tab
(`replies.dart`, `replies_pane.dart`, `gap_hunt.dart`, `gap_walk.dart`), the
Audit tab (`chapter_audit.dart`, `audit_pane.dart`, `lib/chess/audit/`),
`lib/storage/chapter_files.dart` (with `chapter_directory.dart` and
`deleted_chapters.dart`), `pgn_document_store.dart`,
`training_records.dart`, and `lib/chess/pgn/` (chapter, sections, import,
LineID pins). The Expectimax tab is [generation.md](generation.md); the
shared board, tabs and engine are [workspace.md](workspace.md).

## Screen

Mode menu: `Repertoire builder` (group `Repertoires`, with `Opening books`
and `Repertoire trainer`). Columns left to right: the repertoire list, the
outline (only while a whole-file repertoire chapter is open and no training
sitting is on the board), then the workspace. When the window is too narrow
for both, the list and the outline share one column as two pages.

- **List header** — `Your repertoires`, a `+` (`New repertoire`), and
  `Search repertoires` (filters names as typed).
- **Repertoire row** — chevron, name, `3 chapters · Modified 4h ago`; row
  actions `Rename…`, `New chapter…`, `Delete…`. Rows are sorted by name.
  Expanding shows the chapter rows; the open chapter is highlighted.
- **Chapter row** (in the list) — name; `Rename…`, `Move to…` (another
  repertoire, picked from a searchable list), `Delete…`. Row actions are
  disabled while another catalog change runs.
- **List foot** — `Deleted chapters`, which swaps the list for the deleted
  chapters view (`Back to repertoires`, one row per chapter with `Restore`;
  empty: `Nothing deleted` / `Chapters you delete can be restored here.`).
- **List states** — `No repertoires yet.` with `New repertoire`;
  `Nothing matches "q".`; `Could not load repertoires. Please try again.` with
  `Retry`; a folder that could not be read is named above the list
  (`<name> could not be read: <reason>`).
- **Outline header** — `Chapters`, a filter toggle `At this position`, a `+`
  (`New chapter`), and `Find a chapter or line`.
- **Outline chapter row** — name (bold and accented when open; muted with
  `Proposed` for a draft), `12 lines`, and the chapter's root moves under the
  name when it does not start at the initial position. Lines may be dropped on
  any chapter but the open one.
- **Outline line rows** — the open chapter's lines; a `⋯` menu with
  `Move to chapter…`, `Rename line…`, `Delete line`, `New chapter…`.
- **Outline states** — `No chapters yet` / `Create a chapter, then add your
  moves.`; `No chapter or line matches "q".`; `No lines match this search.`;
  `No line reaches this position.`; `Empty — add lines to fill this chapter.`;
  `Some chapters could not be searched.`
- **Outline foot** — `Version history`; while a cross-file line move is
  unresolved, `The line move still needs retrying.` with `Retry line move` and
  `Discard`.
- **Workspace** — board, move note card (editable here, including the
  chapter introduction) and the action panes. The builder opens two panes:
  `Moves` on the left (45%), `Expectimax` on the right and selected; the book
  button under the moves opens the Explorer there, shut at first. Also
  available from a pane's `+`: `Replies`, `Train`, `Audit`, `Analysis`,
  `Game review`.
- **Replies tab** — status line `Their replies · 2200 · 4 gaps · 87%
  covered` (`Our candidates` at our move), a `Next gap` button, then one row
  per move, most likely first: share (`<1%` below one), move, a tick when the
  chapter plays it, and `gap`, or the name of the sibling chapter that answers
  it (`Petroff`, `this chapter`). At our move a column shows the stored
  `[%expectimax]` value, or `not in tree`. Hovering floats the position;
  clicking plays the move. Empty: `Open a chapter to see what they play.`
- **Audit tab** — an `Audit` button (`Stop` while running), a `ChessDB` chip
  (off; `Also ask ChessDB for good replies (sends positions)`), a status
  (`Checked 212 positions · 3 findings`, `Stopped at k of N positions ·
  Audit again to finish`, `ChessDB stopped answering · Audit again to
  finish`), then one row per finding: `12.Nxd5?  Mistake` over `loses 3.2 ·
  best e3 · 1 in 4`, or `3…e6  Strong reply` over `Engine · their best · Maia
  4% · no answer · always`; `Dismiss` per row and `n dismissed` / `Restore`
  under the list. Before a run: `Audit checks your moves and the good replies
  the chapter misses.`; nothing found: `Nothing found.`

## Actions

**New repertoire** — list `+` or `New repertoire` → `Create repertoire` name
dialog → `<name>/Main.pgn` with no side, opened at once (the side question
follows) → `A repertoire named "X" already exists.` /
`Could not create the repertoire.`

**Import a PGN file** — Actions ▸ `Open PGN file…` (Ctrl+O) in this mode, or a
`.pgn` dropped anywhere on the window → a new repertoire named after the file
(illegal characters become `_`, trimmed, then ` (2)`, ` (3)`… until free;
`Imported repertoire` when the name is unusable), opened on its first chapter.
Variations become separate lines (whole games stay whole); a file with two or
more chapters (Lichess `ChapterName`, Chessable player headers) becomes one
course file. It is written in a hidden staging folder and moved into place →
`That PGN has no moves to train.`, `Could not read that file.`,
`Could not import the repertoire.`

**Paste PGN as repertoire** — Actions or Ctrl+V (not on the analysis board,
where Ctrl+V pastes onto the board) → the same import, named
`Pasted repertoire` → `Nothing to paste: copy a PGN first.`

**Choose the side** — a chapter whose file names no side asks
`Which side is <chapter> for?` when it opens and writes `// Color:` into the
file; dismissing leaves it read as White and asks again next time. Import
infers the side when the file does not say: the branching side is the
opponent (needs 8+ lines), else the side most lines end on (4+ lines).
Actions ▸ `Play as Black` / `Play as White` changes it later.

**New chapter** — outline `+`, a line's `⋯`, or a repertoire row's
`New chapter…` → name, plus `Starts`: `From here` (the board's moves become
the chapter's `// Root:`) or `From the start` → the file opens at once with
the repertoire's side → `A chapter named "X" already exists.`

**Rename / move / delete a chapter** — list row actions. A chapter file is
renamed or moved on disk; a course chapter's rename rewrites its
`[ChapterName]` tags; a course chapter cannot move on its own. Delete asks
`Delete chapter "X"?`: a file goes to its repertoire's recovery folder, a
course chapter's games are taken out of the shared file. Training records and
books follow every rename, move, delete and restore; if they cannot,
`Your training records still point at the old name.` A change refused
because the open chapter changed on disk offers `Reload`.

**Rename / delete a repertoire** — the folder is renamed as one move; delete
(`Delete repertoire "X"?` / `Its chapters can be restored from Deleted
chapters under this list.`) moves each chapter to recovery, then removes the
empty folder.

**Restore a deleted chapter** — `Restore` → back under its name with its
training rows; when the name is taken, `Restore as` asks for another.

**Open a chapter** — click its row (list or outline) → it opens in the
workspace; a line row puts the cursor on that line's last move.

**Move lines** — Ctrl-click / Shift-click pick lines; drag them onto another
chapter to make them its lines, or onto a line of the open chapter to fold
them in as variations. `Move to chapter…` does the first by name, and also
offers `New chapter…` (made with the open chapter's side). A cross-file move
writes both PGNs and the training files as one recoverable transaction,
pinning `[LineID]` first; Ctrl+Z restores both chapters. A failed write keeps
the move for `Retry line move` and blocks other catalog changes until it is
retried or discarded. Accepting proposed lines from a draft is this move.

**Rename / delete a line** — the line's `⋯`; deletion is undoable with Ctrl+Z.

**At this position** — the filter toggle narrows the open chapter's lines to
those passing through the board's position (transpositions included) and
follows the board.

**Outline search** — `Find a chapter or line` matches chapter names and
movetext across closed chapters (read on demand after a debounce); matching
lines show under their chapter, and opening it keeps the search.

**Version history** — `Version history · <file>`: earlier versions of the
open file with time and size and a PGN preview; `Restore as new repertoire`
imports the selected version as `<name> (restored)` for review; `Delete
older versions beyond those limits` keeps the newest 100 and the last 90 days.
Nothing is pruned automatically.

**Replies and Next gap** — the Replies tab follows the board. `Next gap` (tab
button or Actions) walks the chapter's gaps most-reached first: a missing
reply lands on the position before it with its row tinted.

**Audit this chapter** — Actions ▸ `Audit this chapter` shows the Audit tab
and starts; the tab's `Audit` does the same. It walks every position the
chapter plays, breadth first, each once, to 30 half-moves. At our moves
Stockfish's three best at depth 14: a chapter move 100 cp or more behind the
best is a `Mistake`, 40 or more an `Inaccuracy`; a missed or allowed mate is
said as `misses mate` / `allows mate`. At theirs, a reply within 50 cp of
their best that the chapter, its sibling chapters and the Replies tab do not
cover is a `Strong reply`. With the `ChessDB` chip on, ChessDB is also asked
(at most 1000 requests a run; it gives up after a refusal or three misses in a
row). Clicking a finding puts the board on the position before the move; a
finding the chapter no longer stands behind drops out at once. The engine pane
reads `Paused while auditing`; one heavy engine job (search or audit) runs at a
time.

**Train** — Actions ▸ `Train this chapter` shows the Train tab (see
[trainer.md](trainer.md)).

## Data

- `Documents/repertoires/<repertoire>/` is a repertoire. Every `.pgn` under
  it, subfolders included, is a chapter file; dot-folders, `.import-*` staging
  folders and `*_raw_games.pgn` are skipped. A `.pgn` directly under
  `repertoires/` is moved to `<name>/Main.pgn` when the list is read.
- A chapter file starts with a `//` heading: `// <name>`,
  `// Color: White|Black`, `// Created on <date time>`, `// Root: 1. e4 e5
  2. f4` when it starts after moves, and `// Draft` for a proposed chapter.
  Then one game per line.
- A course file holds several chapters, each game naming its chapter in
  `[ChapterName]`; an untagged file is one chapter. A chapter is identified by
  (path, section).
- `[LineID]` is a line's training identity. A game without one is trained under an id derived from
  its moves and place, so any edit that rewrites, moves or re-places it pins
  `[LineID]` first. Losing it orphans the line's training history.
- Round trip: untouched games keep their bytes; heading, comments (with
  `[%…]` tokens), NAGs and unknown tags survive.
- Training records in Documents, keyed by chapter path and line id:
  `repertoire_reviews.csv`, `repertoire_review_history.csv`,
  `repertoire_move_progress.csv`, `repertoire_move_attempts.jsonl`.
- Deleted chapters: `<repertoire>/.cap-pgn-history/`. Reference rewrites keep
  prior text under `Documents/.cap-reference-history/`. Versions:
  `<support>/backups/<document id>/` with `index.json`, following the file
  through renames.
- Audit: `audit.db` (engine lines, so a rerun only asks about new positions),
  `audit_dismissed.db` (dismissals keyed by kind, position and move, so they
  survive renames) and `eval_cache.db`, all in the support folder. When
  dismissals cannot be saved: `Dismissals could not be saved; they last only
  until you audit again.`
- Search trees and drafts: `.cap-generation/` beside the chapter
  ([generation.md](generation.md)).
- Course import rules, measured against four Chessable exports
  (`chess/pgn/repertoire_import.dart`, `chess/pgn/chapter_grouping.dart`):
  a bracket at the *opponent's* move is coverage, at *our* move it is the
  author mentioning what they do not recommend (it made `3.e5` "book" for 132
  of 387 sample games), so every expanded sideline records its branch points
  in `[BranchPlies]`. The chapter header (`[White]`, `[Black]` or `[Event]`)
  is the one whose values come in the fewest contiguous runs; counting
  distinct values instead split one course into 1,313 chapters. Identical
  lines are kept once (one export listed 24 lines under 24 titles). A large
  course is parsed on another isolate: one export is 1,179 games that expand
  to 16,285 lines, about 7 s of work.
- Also read by: Repertoire trainer, Opening books (`books.json` selectors
  follow renames), My games, the PGN Viewer's `My books` tab, the explorer's
  `Book` source, Player analysis.

## Owner decisions

- **One mode, named for the building** (2026-09-21, 2026-09-22). The library
  and the builder are one mode, `Repertoire builder`. No Build switch: a move
  played on a repertoire chapter is saved. Reading a file is the PGN Viewer's
  job.
- **Actions beside the mode menu** at the top left; the settings gear alone at
  the top right (2026-09-22).
- **One loop, as Chessbook does it** (2026-09-21). The Replies tab and Next gap
  are the question loop. Maia is the only source of reply shares, gaps and
  coverage, at the `Opponent rating` setting (default 2200); the Explorer is
  where the user looks up what masters and Lichess play (2026-09-22).
- **What a gap is** (2026-09-21/22). A reply reached at least once in N games
  (`Cover replies met once in`, default 50, 5–1000) at the opponent rating with
  no move of ours. Reach is the product of opponent shares from the chapter
  root; our moves count as certain. Coverage takes the least-covered choice at
  each of our turns; exclusive choices are never added together. A reply that
  another chapter of the repertoire (or another line of this one) answers is
  not a gap; draft chapters never count as answers.
- **The side is asked once, never switched** (2026-09-22). No White/Black
  control on the card; `Play as Black` / `Play as White` in Actions.
- **Import has no form** (2026-09-22). File or paste becomes a repertoire
  named after the file and opened; rename from the list. A course becomes one
  file with `[ChapterName]` tags; edits splice back into it.
- **The outline stays as it is** (2026-09-22). Repertoire list, chapter
  column, lines under the open chapter. No folder creation, folder moves or
  folder rows; folders already on disk are read as they are.
- **Chapters have a visible root** (2026-09-21): `// Root:` shows under the
  name; `New chapter` offers `From here`.
- **A draft is a chapter** (2026-09-21): `// Draft` shows it as `Proposed`;
  accepting lines is dragging them into the real chapter.
- **Expectimax values ride in comments** (2026-09-22). The Replies tab shows
  the stored `[%expectimax]` at our move or `not in tree`; nothing is computed
  while browsing (2026-08-21).
- **Audit scope** (2026-09-28): the chapter's own moves and the good replies
  the Replies walk leaves out. Coherence, line metrics, coverage reports and
  the trap tour are not ported; player-specific findings live in Player
  analysis ([players.md](players.md)).
- **Fail open** (2026-09-25): an unreadable folder or chapter is named and
  skipped; it never blocks the rest of the library.
