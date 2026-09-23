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
or panel close stops it.
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
- **Comments are laid out**: paragraphs, inline moves (hover board, click plays into the document
  when the line follows on from the move), bare-FEN diagrams, Chessable headings and quotes.
- **One Actions menu** in the top bar, the same shape whatever mode opened the document, with Ctrl+K
  as a typeable palette over the same list.
- **Solitaire is an action of the viewer**, not a mode. **A file outside Documents is copied into
  `pgn_collections` on open** (default on; a setting later). Autosave stays on; Scid export and
  paging remain open questions.
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
  `Sicilian – Najdorf`). Search unfolds the chapters it finds games in. A plain collection stays
  the flat list.
- **The start of a game names its first move.** The note under the board shows the game's
  introduction, then the first move muted with its note; clicking it plays it, as → does. Hidden
  while a line is being found (puzzles, training).
