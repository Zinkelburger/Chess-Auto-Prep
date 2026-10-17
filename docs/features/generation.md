# Expectimax search (generation)

The Expectimax tab searches from the position on the board and shows what each
move is worth against how real opponents reply. Someone preparing a chapter
runs it, reads the values as the board moves, and, when they want lines, has
the best of them written into a draft chapter beside theirs. Every run also
feeds the Positions list (traps, only moves, practical choices).

Code: `lib/workspace/fill_gaps.dart` (`FillGaps`, the one run at a time),
`search_pane.dart`, `search_settings.dart`, `search_table.dart`,
`fill_states.dart`, `fill_lines.dart` (a run's draft lines),
`search_opponents.dart`, `generated_draft.dart`,
`finds.dart`, `finds_panel.dart`, `engine_jobs.dart`; `lib/app/search_door.dart`
(Ctrl+G) and `lib/app/trap_training.dart`; the pure core in
`lib/chess/generation/` (`search.dart`, `mainline_book.dart`, `finds.dart`,
`traps.dart`, `draft_lines.dart`, `draft_chapter.dart`, `tree_wire_v4*.dart`);
storage in `lib/storage/generation_trees.dart`, `finds_store.dart`,
`eval_cache.dart`; remote lookups in `lib/net/search_evaluator.dart` and
`remote_queue.dart`. Search policy and invariants:
[ALGORITHM.md](../ALGORITHM.md#interactive-expectimax-search-tab) ("Interactive Expectimax").

## Screen

The `Expectimax` tab of the action panes: open and selected by default in the
Repertoire builder (on a chapter or the analysis board), and offered in Player
analysis. Modes without the tab (Tactics, My games, the trainer) start no
search.

- **Bar** (never moves) — one filled button that reads `Expectimax`, `Pause`,
  `Resume` or `Deeper` (`Build` for the mainline book) in the same place;
  `Depth` (empty is `No limit`; 1–64); a Positions button; a gear
  (`Expectimax settings` / `Show results`); and the typeable `Replies from`
  field (`Maia`, `Lichess masters`, `Lichess players`, `TWIC games`), beside
  the depth when the pane is wide enough, else on its own line.
- **Status line** — the side being prepared (`White` / `Black`) as a text
  button that turns the board (as F does; held while running), then what will
  run (`Maia 2200 · best 4, then 4`), or progress (`Depth 3 of 8 · 95
  positions`, `Stopped at depth 3 · … · ChessDB stopped answering`), or the
  failure in the error colour. At its end: `Finish depth N` while a search
  with no depth runs; `N found` after a run that found positions (opens the
  Positions list).
- **Table** — at our move `Your move`, at theirs `Their reply`, then
  `Played`, `White`, `Black`, `Engine`, all from White's side. `White` is the
  move's value when White plays its best and Black replies as players do;
  `Black` the reverse. `Played` is dropped first when the pane is narrow. A
  Maia stand-in share reads `~38%` with `~ Estimated by Maia where database
  games are sparse.`; a trap reply is marked `?` (`Trap: Played 34%, loses 1.8
  against their best`). Hovering an Engine value names its depth (`Depth 22`,
  or `Depth unknown (saved or database result)`). The mainline book shows one
  `Value` column. Clicking a row plays the move; hovering floats the position.
- **Table states** — `Press ▶ Expectimax to evaluate moves from this
  position.`, `Evaluating the first moves…`, `The game is over here.`,
  `Not reached yet.` / `The search stopped before this position.`,
  `No saved results here yet.`, with `Go to where it started` when that line
  is still in the document.
- **Foot** — `Make lines` (`Write the best moves as lines in a draft chapter
  beside this one, traps marked ?`), then `8 lines in Main (draft)` with
  `Open`. Save failures show `Retry saving tree` / `Discard tree save` and
  `Discard draft save`.
- **Gear** — `Method`: `Maia practical` | `ChessDB mainline`. For Maia
  practical: `Maia rating` (hidden when Maia is never asked), `Fall back to
  Maia under` N `games at a position` (database sources only), the Lichess
  speeds and ratings from the Explorer tab (Lichess players only), `First
  move` and `Later moves` (our best engine moves searched, default 4 each),
  `Search replies met once in` (default 100; 0 searches every reply), `Engine
  depth` (default 14, 1–40), `Evaluation` (`Engine`, `ChessDB`, `Lichess`).
  While running: `Pause the search to change these.` The same settings are in
  Settings ▸ Expectimax (`Settings.expectimax` in `settings.json`).
- **Positions list** — replaces the left list column (Ctrl+P, the bar's
  Positions button, or `N found`; Ctrl+P again restores the list). `Top` |
  `Often` | `New` ordering, a typeable `Kind` field (`Every kind`, `Trap`,
  `Only move`, `Their only move`, `Practical`), `This chapter` (on when a
  chapter is open). A row reads `4.d4 Bc5?  Trap` over `played 29%, loses 1.7
  · 1 in 3 · as White`; `⋯` offers `Train this line` (traps) and `Remove`.
  Empty: `Nothing found yet. Run a search from the Expectimax tab; what it
  points out is listed here.`

## Actions

**Search** — `Expectimax`, Actions ▸ `Expectimax from here` or Ctrl+G
(where the tab exists and a position is on the board and not hidden; nothing
is written to the document) → searches the board for both sides on the one engine: for the
side at the bottom and, with roles swapped, for the other; the second tree's
failure never fails the run. The engine pane reads `Paused while searching`.
Values appear level by level. Refusals: `A search is already running.`,
`Nothing is on the board.`, `Finish the puzzle first.`,
`Finish saving the previous search tree first.`

**Pause / Finish depth** — `Pause` stops after the position under way and keeps
the tree; `Finish depth N` scores the whole current level, then pauses. A
search with no depth runs until paused or its 25,000-new-position budget.

**Resume / Deeper** — `Resume` shows where a tree with the same settings
covers the board (in memory, else the newest saved tree for this board) and
continues from the board; `Deeper` shows where that tree already reaches the
asked depth and raises `Depth` by one. A saved tree that cannot be read is
passed over for an older match → `No saved search is available for this
board.`

**Follow the board** — navigating while a search runs stops it, saves its tree
and restarts from the new position, reusing compatible values; a stopped
search stays stopped while browsing.

**ChessDB mainline** — `Build` → our move is ChessDB's best (ties to the move
masters played most); their replies are the masters' moves from
`master_games.db` (at least 10 games, until 80% of games or 4 replies) within
`Depth` half-moves (empty is 8); past that, or where masters never went,
ChessDB's best reply, each line to at most 40 half-moves. ChessDB refusing or
1,000 requests stops it with what it built; `Resume` continues.

**Remote evaluation** — `Evaluation` ChessDB or Lichess sends positions only
when chosen, one request at a time, at most 1,000 per run; misses fall back to
Stockfish and an outage hands the rest of the run to Stockfish. Remote scores
never enter `eval_cache.db`.

**Make lines** — on a writable repertoire chapter, for its side, after a run →
a draft chapter `<chapter> (draft)` (then `(draft 2)`…) beside it: one game
per line the search answered, most reached first, at most 100; near-copies
fold into a kept line as a sideline of at most 6 plies or are dropped; lines
whose every move of ours the chapter already plays are left out; trap lines
follow the lines. Each line is continued by up to 6 plies of Stockfish's best
line, unvalued (not for the mainline book). Refusals: `The search found no
line the chapter does not already have.`, `The chapter was moved, renamed or
deleted since …`. A write with an uncertain outcome is retried with the same
path and bytes, never written twice.

**Open a position** — click a Positions row (or ↑/↓ while the list is up) →
the position in the open chapter when it plays the line that far, else the
whole line on a new analysis board from the searched side.

**Train this line** — a trap's `⋯` → the line is found in the open chapter or
a sibling and trained in the Train tab; otherwise, asked once, it is added to
the chapter's draft and trained there.

## Data

- **Draft chapter** — a normal chapter file with `// Draft` in its heading
  ([repertoires.md](repertoires.md)). Each game is named (`Event`, plus
  `ECO`) after the last position of its main line the bundled opening book
  names, else the draft's name; carries `[CumProb]`. Every move's comment
  carries `[%expectimax +0.42]` (centipawn equivalent of the expected score)
  and `[%score 53.8%]`; a line's first move `[%cumProb 29.3%]`; trap replies
  are written with `?`. The values follow a line dragged into a real chapter.
- **Search trees** — v4 `tree.json` under
  `<repertoire>/.cap-generation/<chapter>.pgn/v2-<run id>/`, written under the
  document lock. Each save keeps that run plus the newest 16 earlier `v2-*`
  runs of the chapter; `v2-agent-*` runs and other entries are never pruned.
  A tree with no horizon is written as `max_depth` 512. Narrowed trees carry
  algorithm version 4. A search not started on a repertoire chapter (the
  analysis board, Player analysis) keeps its tree in memory only.
- **Finds** — `finds.db` in the support folder: one row per kind, side and
  position, replaced by a newer finding; at most 1,000 per run.
- **Engine cache** — `eval_cache.db` in the support folder, keyed by position
  and depth, shared with the audit.
- **Agent searches** — the chess-prep MCP `expectimax_run {chapter}` writes
  `v2-agent-<run id>/tree.json` beside the chapter (engine depth 14, no loss
  window, the chapter's side), which the app's `Resume` continues;
  `expectimax_resume {chapter}` copies a compatible app tree into a new run,
  never editing it (`tools/mcp/chess_prep/expectimax_chapters.py`).
- Read by: the Replies tab's expectimax column (comment tokens), the Positions
  list in every mode with a list.

## Invariants

- One heavy engine job at a time (`EngineJobs`: a search, its draft lines, or
  an audit); the board's engine waits.
- A search never writes into the chapter it was started from.
- Resume reuses a tree only when side, rating, reply source (and fallback),
  evaluation source, engine depth, candidate counts and reply coverage match;
  values of different settings are never mixed.
- An engine or model that cannot answer one position stops the run, not the
  tree: what was built is saved, offered to `Make lines` and resumable. Only a
  board that cannot be scored at all fails the run.
- A database reply source that cannot be asked stops the run with its own
  sentence; it never silently becomes a Maia search.
- Find kinds and thresholds: trap (reply played ≥ 20% losing ≥ 50 cp against
  their best, leaving us ≥ 0 and ≥ 50 cp above our best at our last turn),
  only move (others lose ≥ 150 cp, our best between −150 and +300), their only
  move, practical (≥ 30 cp worse for the engine, ≥ 0.02 better in expected
  score); a line whose own moves give up more than 300 cp is left out
  (`lib/chess/generation/finds.dart`, `traps.dart`).

## Owner decisions

- **A search gets the values; lines are asked for** (2026-09-23). No launch
  dialog; `Make lines` is a separate step after a run.
- **Explore, don't prune** (2026-09-23): the finds are kept globally and
  browsed in the Positions column, not per run. The shortlist of our moves
  (`First move` / `Later moves`) replaced exhaustive search on 2026-09-27; see
  ALGORITHM.md.
- **A run never writes into the chapter** (2026-09-21): it writes a draft
  chapter beside it; deleting the draft discards the run; near-copies fold
  into their host (the line-diversity bar).
- **One button, one bar** (2026-10-01): Expectimax/Pause/Resume/Deeper in one
  place; the side is a flip button, never a White/Black switch.
- **Both sides in one press** (2026-10-01): `White`, `Black` and `Engine`
  columns; status, Positions, traps and `Make lines` belong to the board's
  side.
- **Replies from Maia or a database, one source per position** (2026-10-01),
  with Maia as fallback under N games.
- **Nothing is computed while browsing** (2026-08-21): stored values only;
  a missing one reads `not in tree`.
