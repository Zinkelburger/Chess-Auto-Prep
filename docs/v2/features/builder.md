# Repertoire builder

Status: folded into repertoires.md on 2026-09-21 (owner: no builder mode); oracle for the old outline and save behaviour only
Old code (oracle only): `lib/screens/repertoire_screen.dart`, `lib/screens/repertoire/`,
`lib/features/repertoire/`, `lib/features/repertoires/`, `lib/services/repertoire_file_editor.dart`,
`lib/chess_core/pgn/repertoire_*.dart`, `lib/widgets/chapter_list_body.dart`, `lib/widgets/lines/`
Plan step: 2, 4

No screenshot: this pass was asked not to start the app driver.

## Purpose
Someone who already has a repertoire on disk opens it here to organise it into folders, chapters and
lines, and to write the moves, variations and notes they intend to train. They leave with the chapter
file holding exactly what the screen showed, and training progress still pointing at it.

Generating lines (builds, planner, Jobs pane) is [generation.md](generation.md); holes, coverage, the
audit and the Findings pane are [checks.md](checks.md).

## Screen
Reached from the mode menu (`Build` → `Repertoire builder`), from the Repertoires library by opening a
repertoire (its first chapter), from the Trainer's "Explore this position" (a line id plus a move
sequence), and from the Viewer's `Edit this chapter in the Repertoire Builder`; a handoff may demand a
reload from disk. Wide: outline column, board, then moves and comment over Engine / Database docks,
above a badge status bar and a collapsed Findings / Jobs pane (checks.md, generation.md). Under 960px
those panes become `PGN` / `Chapters` / `Database` / `Engine` tabs below the board.

- **Title bar** — `Repertoire Builder` while loading, then repertoire ▸ chapter; the chapter part opens
  a searchable `Switch chapter` picker (`Search chapters`, rows subtitled `N lines`, plus `Add chapter`
  and `View all chapters`; `Could not load chapters. <error>`). Switching keeps the workspace mounted
  behind a thin loading bar and a brief input lock, and a write still in flight cannot reach the new
  chapter → `Failed to load repertoire: <error>`.
- **`Actions ▾`** — GENERATE (`Plan the lines…`, `Generate from here…`) · IMPORT (`Import PGN…`) · TRAIN
  (`Train this chapter`) · CHECK (`Audit for gaps…`) · `Check disk for changes` · `Generation settings…`
  · `Settings…` · Library (`Choose repertoire…`). Then the mode switcher and a gear: `Repertoire
  options` — `Side you play` / `Apply playing side` (locked during a build), `Board size`.
- **Outline column** — header `Chapters`, an options menu (a disabled `N chapters · M lines`, and `Line
  metrics`, which swaps the column for the coverage and traps browser — checks.md), `Hide chapters`, `+`
  = `New chapter`. Resizable (min 220px, default 18% of the body clamped 220–280px, max 45%), collapsing
  to a 28px strip. Rows are 30px and indent 14px per level: folders (bold name, total lines beneath),
  chapters (own chevron, bold and accented when on the board, a planner badge `queued` / `creating…` /
  `building…` / `skipped` / `failed`, and the count of lines passing the filter), course sections of an
  imported chapter (`Other lines` when untitled) and lines (name, first 8 plies in mono). An unfolded
  empty chapter reads `Empty — add lines to fill this chapter.`, and the active chapter is always
  revealed.
- **Outline search and empty states** — a visible `Find a chapter or line` box (200 ms debounce,
  matching names *and* movetext, force-unfolding every hit) and a `Chapter filters` menu holding one
  item, `At this position`. Empty: `No repertoire open`; `No chapters yet` / `Create a chapter, then add
  your moves.` with `Plan the lines` and `New chapter`; `No chapter or line matches "<text>".`; or
  `Could not read this repertoire` with `Retry`.
- **Board and moves** — the shared workspace (`workspace.md`): board, a navigation row (`Go to start`,
  which keeps the loaded line, plus back/forward, `Generate from here…`, `Flip board` and board size),
  the editable move list, the `Comment` panel and the Engine / Database docks.
- **Save-state banners** — stacked above everything, the only save feedback there is: `Copy needs
  verification: {destination}.` with `Inspect copy`; `Line edits are retained. Saving failed.` with
  `Retry`; `The source changed or is missing. Restored edits are a scratch line; save them to an
  explicit destination.`; `Save draft as a new line…`; `Retained drafts ({count})`.

## Actions
**Add a chapter or folder** — `+`, `New chapter next to this…`, a folder's `New chapter here…` / `New
folder here…`, or right-click on empty space; `New chapter` / `Chapter name` / `Create`, and it opens on
the board at once → `"Advance" already exists in Sidelines.`, `Chapter creation needs verification:
<path>. Recovery: <path>. Do not retry.`
**Rename** — `Rename…` on a folder, chapter or line; an unchanged name cancels. A chapter is a file, so
names obey filesystem rules, capped at 120 characters → `Names cannot contain < > : " / \ | ? * or
control characters.`, `A chapter named "X" already exists here.`
**Move and reorder** — `Move to folder…` / `Move [3 lines] to chapter…` / `Move [3 lines] to a new
chapter…` open a path picker whose root row reads `<name> (top level)`. Dragging does the same: a mouse
drag starts on first movement (touch after 250 ms) and a chip follows the pointer (`<line> · 1.e4 e5` or
`3 lines`); a line dropped on a chapter is appended; on the top or bottom half of a line row it lands
there, in that chapter or its own; on a folder or the drag-only foot zone (`New chapter from 3 lines at
the top level`) it starts a new chapter. Chapters and folders drop only on folders or that zone, never
into themselves, a descendant or their current parent; a collapsed target springs open after 600 ms and
the list auto-scrolls within 40px of its edges. Ctrl/Cmd-click toggles a line into the selection and
Shift-click extends it, within one chapter → `Another outline change is still running. Wait for it to
finish.`, `A folder cannot be moved into itself.`
**Undo an outline edit** — moves, reorders, deletions and a chapter made from lines report in a toast
carrying `Undo` for 8 seconds (`Deleted 3 lines.`, `Made "Qb6" from 1 line. Undo returns the lines and
keeps the chapter.`); it restores the exact former indexes and re-points training progress, and a second
edit kills the offer. Creating, renaming, splitting and deleting a chapter or folder are not undoable.
Board editing has its own Ctrl/Cmd+Z, 20 steps deep; there is no redo.
**Delete** — `Delete [3 lines]` runs with no confirmation (Undo is the only safety net); chapters and
folders confirm (`The chapter will be removed from this folder and kept in recovery storage.`; `N
chapters and M lines inside it will be moved to Chess Auto Prep recovery trash.`) → `Chapter moved to
recovery:\n<path>`, `The chapter changed since deletion was requested. Nothing was removed.`, or
`Deletion could not be confirmed. Check these locations before taking another action; do not retry
automatically:\n<paths>` in a `Review chapter deletion` dialog.
**Split a course chapter** — `Split into chapters…`, only when the file carries two or more course
sections → `Split "X" into 4 chapters?` / `12 lines move into new chapter files named after the course's
own chapters, and their training progress moves with them.` A partial failure lists written and
unconfirmed paths in a `Review chapter split` dialog and never retries.
**Edit moves, variations and comments** — play on the board or click an explorer move; a move at a
branch point becomes the last variation. The move menu holds `Add Comment`, `Start Quiz From This Move`
/ `End Quiz After This Move`, `Promote Variation`, `Make Main Line`, `Copy Whole Line`, `Copy PGN from
Here`, `View in Lines` and `Delete from Here`; the `Comment` panel edits the move under the cursor, or
the chapter introduction at the start position.
**Save** — no save button, no dirty marker: every structural edit and every title change writes the
whole line back at once, atomically and under a directory lock, refusing a file that changed since it
was read, with overlapping writes collapsed into one pending replacement per line → `Line edits are
retained. Saving failed.` (Retry), `Line was saved, but refresh failed: <error>`. When the destination
is gone, `Save draft as a new line…` writes a copy → `That destination already exists. Nothing was
replaced. Choose another name for your copy.`, or `Copy needs verification: {destination}.` with
`Inspect copy`, opening `Verify the saved copy` — `Confirm only if the intended line is present in this
observed file. Keeping the draft does not repeat the append.` Nothing is ever retried automatically.
**Import a PGN** — `Import PGN…` takes a file or the clipboard in one window, confirm `Add to
repertoire`; each root-to-leaf path of an imported game becomes its own line and duplicates are dropped
→ `Added 7 lines to repertoire.` A chapter switch aborts the import.
**Check disk for changes** — a modal that cannot be dismissed by tapping away, then `No changes on disk`
(`The file still holds the same 24 lines that are open here.`), `Reloaded from disk` with `New lines
found on disk`, `Lines no longer in the file` (12 names, then `and 5 more`) and `3 lines kept the same
moves but changed elsewhere — a comment, a glyph, or a sub-variation.`, or `Could not read the file`.
Lines match by movetext, not by id.
**Publish generated lines** — a finished build hands its course to the chapter that started it: pending
edits are drained and the document is adopted atomically, so a stale or replayed result cannot append
twice; a conflict or unconfirmed write keeps the proposal on disk and names its path (generation.md).
**Keyboard** — Ctrl/Cmd+Z undo, Ctrl/Cmd+Shift+V paste FEN, `F` flip, `E` engine, ←/→ and Home/End
navigate, ↑/↓ step findings or trap stops, Escape collapses the bottom pane. Outline editing has no keys
of its own.

## Data
- `Documents/repertoires/<repertoire>/…` — folders are folders, a chapter is one `.pgn` file, a line is
  one game in it; a legacy flat `<name>.pgn` migrates once into `<name>/Main.pgn`.
- Above the first `[Event ` a chapter carries `// <chapter name>`, `// Color: White|Black`, optionally
  `// Chapter: <course chapter>`, `// Created on 2026-09-19 14:32:07` and, once a root is set,
  `// Root: 1. d4 d5 2. c4`; each is upserted in place. Anything but `// Color: Black` (ignoring case)
  reads as White; with no colour line the first `[Event]` tag ("… : Repertoire for Black") decides; only
  when neither says does `Which color is this repertoire for?` ask, once, and write the answer back →
  `Playing side was not saved: <error>`.
- Each game is one line: `[Event]` its title, `[White]`/`[Black]` naming sides rather than players (`Me`
  / `Training`, older writes `Me` / `Opponent` with `[Result "1-0"]`), `[Result "*"]`, and `[FEN]` +
  `[SetUp "1"]` when the chapter does not start from the initial position — every line in a chapter
  shares that root, and a game starting elsewhere is skipped by readers. `[LineID]` (also read as
  `LineId`, `Id`, `Line`, `Guid`) is the identity every later lookup uses; the SM-2 headers
  (`LastReview`, `Difficulty`, `Interval`, `DueDate`, `PassCount`, `FailCount`), `[CumProb]` and
  `[Annotator "Chess Auto Prep"]` ride on the same game.
- A round trip must keep all of it. An edit cuts the file into preamble plus games, rewrites the
  smallest span that must change and writes it back through a temp file and a rename, refusing content
  that changed underneath: untouched games stay byte-identical in place, tags the editor does not model
  are merged back, standard headers keep a fixed order and comments keep their `[%…]` tokens
  (`workspace.md`). Losing `LineID` orphans a line — rename, save and delete then fail silently.
- Beside a chapter, skipped by every listing: `.cap-generation/<chapter.pgn>/…` (proposals, artifacts,
  receipts) and `.cap-pgn-history/<sha256>.bytes` (the pre-write baseline of every native write and
  every quarantined chapter, never pruned). No index file exists; counts are read off the files.
- Training progress lives in `repertoire_reviews.csv`, `repertoire_move_progress.csv` and
  `repertoire_review_history.csv`, keyed by chapter path and line id; every move, split and undo
  re-points those rows, and a line crossing files first gets `[LineID]` pinned into its text.
- The Trainer (which writes the SM-2 headers back), the Viewer's `My books`, the audit, holes, coverage,
  the planner and Player analysis read the same files.

## Keep / Change / Drop
Keep — Title bar
Keep — `Actions ▾`
Keep — Outline column
Keep — Outline search and empty states
Keep — Board and moves
Keep — Save-state banners
Keep — Add a chapter or folder
Keep — Rename
Keep — Move and reorder
Keep — Undo an outline edit
Keep — Delete
Keep — Split a course chapter
Keep — Edit moves, variations and comments
Keep — Save
Keep — Import a PGN
Keep — Check disk for changes
Keep — Publish generated lines
Keep — Keyboard

Quirks to rule on: the shared toast helper drops every non-error message, so none of the success toasts
above actually appear — and with them the `Undo` button never appears either, although the undo paths
work, leaving line deletion with neither a confirmation nor a visible way back. Saving is silent and
immediate with no dirty marker, yet failures surface as stacked banners plus a hidden pile of retained
drafts, and no saved/saving/failed state anywhere. `// Root:` is written but nothing shows it.

## Questions for the owner
- Once toasts actually show, should every outline edit be undoable (rename, create, split, chapter
  delete) or only moves and deletions — and should deleting lines confirm as well?
- May a chapter hold lines with different roots, or must `// Root:` bind the whole file?
- Do folders survive, or do chapters become one flat searchable list?
