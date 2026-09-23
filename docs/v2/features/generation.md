# Generation

Status: corrected by the owner (2026-09-21: decisions below; built 2026-09-22 as `Fill gaps from here…`; since 2026-09-23 the Search tab, see the last section)
Old code (oracle only): `lib/features/generate/`, `lib/features/generation/`, `lib/features/planner/`,
`lib/widgets/generation/`, `lib/widgets/repertoire_generation_tab.dart`, `lib/widgets/layout/jobs_panel.dart`,
`lib/core/generation_session_controller.dart`, `lib/services/tree_build_service.dart`
Plan step: 7

## Purpose
Someone with a chapter open wants lines written into it rather than typed: they point the search at the position
on the board, set how deep and how wide, and leave it running. They come back to a finished tree, decide how much
of it to keep, and the lines land in the chapter's own PGN.

## Screen
Reached from the Builder's `Actions` menu, group **GENERATE**: `Plan the lines…` and `Generate from here…` (also
the board toolbar, the outline's empty state, and `Build ChessDB repertoire…` in the Generate pane's overflow);
`Recover generated outputs…` is lower in that menu. Every control is disabled while a build runs. No screenshot.

- **Starting-position card** — `GENERATING FROM`, the FEN and move prefix, `Preparing White` / `Preparing Black`;
  the search starts from the *board*, not the chapter root.
- **`WHAT TO BUILD`** — `Build from`, a typeable choice, not a menu: `Engine + human model (recommended)`
  (default), `Database win rates (no engine)`, `ChessDB mainline book`, `My PGN files`, each with a sentence of
  its own. `Only traps` (off). `PGN files used for this build:` shows only for My PGN files.
- **`OPPONENT`** (`OPPONENT REPLIES` in book mode) — `Opponent rating (Elo)` **2200** (500–3500); `Target master
  opponents` / `Cover replies from master games`, on; and, when that database is empty, `Download master games
  first (about 8 GB, once)`.
- **`SEARCH`** (`BOOK SIZE` in book mode) — `Pure` (default) vs `Fast · 4-ply`, engine mode only; `Max line length
  (half-moves)` **4** (1–200; `Pure supports at most 64 half-moves`); `Stop after (minutes)` **0** = no limit.
  Book mode instead: `Branching depth` **4**, `Line limit` **40**, `Opponent replies per position` **4**, `Reply
  coverage (0–1)` **0.80**.
- **`Your lines & structures (optional)`** — lines to pin, one per row, and three veto chips, all off (`Avoid a
  pawn on d5`, `…on e5`, `Avoid an early queen trade`). Hidden in engine mode.
- **`Evaluation databases (optional)`** / **`ChessDB source (required)`** — `Each source is asked in turn; the
  first hit wins and Stockfish only runs when they all miss.` Four sources, each with `Use during builds`: the
  ChessDB dump, a `.db` slice, Lichess evals, and `ChessDB API` (on, `Daily quota` **5000**, `Concurrency` **2**).
- **Presets and summary** — `Presets (3)…`: `ChessDB compact repertoire`, `Reset to defaults`, `Save current as
  preset…`, the saved names with `Delete preset`. The compact preset is 20 branching plies, 34 total, 5 replies
  after the root, 0.90 coverage, 12,000 nodes / 120 minutes, ECO chapters, no verification.
- **`Advanced…`** — `Everything on the main form stays in sync with these.`, a `SECTIONS` rail, ten sections in
  build order: `Opponent model`, `Move choice` (`Maximum engine loss (cp)` **30**), `Search tuning`, `Master
  games`, `ChessDB book` (tie-break window **0**; `Let Stockfish finish lines ChessDB cannot`, off),
  `Verification`, `PGN output` (`Engine continuation plies` **6**, line ordering on, four annotation toggles off),
  `Chapters` (grouping on, ECO chapters off, **40** / **5** lines per chapter, `Model games` **6** at **2200**),
  `Extra variations`, `PGN source filters`. A section that cannot apply prints one sentence saying why.
- **`Generate Repertoire`** — the one filled action, the run status or last summary beside it.
- **Run overlay** — a spinner over the whole tab: `Generating Repertoire...`, `This tab is locked while your
  repertoire builds.`, the live status line (`Phase 1: Building tree...`) and `Pause`; parked on the download it
  reads `Downloading Master Games...` with `Start now without them`. Paused it becomes a `Resume` / `Discard`
  banner.
- **Jobs panel card** — the phase (`Building tree`, `Enriching evals`, `Computing ease`, `Calculating expectimax`,
  `Selecting repertoire`, `Verifying moves`, `Extracting lines`, …), the config summary, elapsed, a bar, and a
  stat line: `Depth 6/12 · 48210 nodes · 180/300 explored · 940 positions/min · depth ETA ~4m` — Fast gives
  `deepest ply 9/12 · 640 positions queued`, one bar per ply and a resource chip. `Export Lines` and `Finish Now`
  sit beside `Pause` / `Cancel`, tree phase only.
- **Unfinished-build card** — `Unfinished build available`, `48210 nodes, depth 9`, and `Resume Exploring` /
  `Finish Now` / `Discard`.
- **Results** — the run summary sentence, then `HOW MUCH TO KEEP`: a slider reading `96 of 140 lines · covers 87%
  of this build's weighted lines`, a note about folded-in near-duplicates, and `Remove 44 lines`. There is no
  diff and no preview of what was written.
- **`Turn this repertoire into a study`** — `Target moves of your own` (**4**, 2–6), `Prefer less repeated
  practice` (on), an exercise slider and `Create and open study copy`.
- **Planner** — its own route, `<repertoire> ▸ Plan the lines`, with `Start › Choices › Plan` chips, a `PLAN SO
  FAR` rail (`12 answered · 5 open`, the decisions, `CHAPTERS · 7` by opening family) and `Finish now`. **Start**:
  `Starting lines — one per row`, `Choose ECO openings…`, then `Guided choices` vs `Use these positions`, and
  `What should the questions walk?` — `Opening book` (default) or `My games` (`4182 of your games as White. Every
  position you reached often enough is a question, with what you played pre-ticked.`). **Choices**: one question
  per position — `How do you play here?` or `Which replies do you want to set up?` (`… the ones you met in 8 games
  or more come ticked.`) — over a table with columns `MOVE`, `MAIA`, `CUM. PROB`, `EVAL`, `YOU` / `VS YOU`,
  `NAME`, under `Continue`, `‹ Back` and `Generate from here`. A repeat position offers `Use that line` or `Set
  up this move order separately`; a thin line stops with `Your games thin out here…`. **Plan** reviews `7 chapters
  to create`, each renameable, over `BUILD SETTINGS FOR EVERY CHAPTER`, ending in `Create chapters only` or
  `Create 7 & generate`.
- **Planner banner** — `Creating chapters…`, then `Building Najdorf · 3 of 7`, with `Pause` / `Resume` and
  `Finish later`; the outline badges each chapter `queued`, `creating…`, `building…` or `failed`.
- **`Recover generated outputs…`** — retained runs with their recorded source and configuration, a source-revision
  comparison, checksums and any receipt, over `Saved tree`, `Saved probes`, `Saved traps`, `Unfinished build`,
  `Generated PGN proposal` and `Model games`, with `Export original file…`. It never resumes a build.

## Actions
**Start a build** — `Generate Repertoire` → the route closes, the tab locks, the engine takes over from
interactive analysis and the job appears in the Jobs panel. Validation is a snackbar, never inline: `Max line
length: must be 1–200.`, `"Database win rates" needs at least one evaluation database.`, `The chapter changed.
Close this configuration and open it again.` Master games missing and wanted → the run parks on the download
until it finishes, `Start now without them`, or cancel; a failed download is silent.
**Pause / resume** — the partial tree is written to disk, the engine handed back and the tab unlocked. `Resume`
re-takes the engine, then continues toward the `Max line length` now in the form. Refused in the short passes:
`This phase finishes on its own and cannot pause`.
**Finish Now** — stops exploring and builds lines from the tree as it stands, skipping verification. No
confirmation; the summary ends `Verification skipped (finished early).`
**Export Lines** — `Export Lines So Far` mid-run: a new repertoire name, optionally `Verify with engine before
export`; the run keeps going → `Exported 42 lines to "X" (verified).`
**Cancel** — immediate, no confirmation; the card reads `Cancelling…` and no new build can start until the unwind
finishes. The partial tree is saved: `Build cancelled (48210 nodes) — resume it anytime from the Generate tab.`
**Discard** — from the paused banner, `Discard this build?` → `The paused build and everything it has explored so
far will be moved to Chess Auto Prep recovery trash and will no longer be resumable.` The unfinished-build card's
`Discard unfinished build?` instead keeps it in recovery history, unresumable.
**Publish** — not a button: the last phase of a successful run. The proposal and any model games stage in full
before the chapter is touched, then the games are *appended* to the chapter PGN against the source revision
captured before the run began; lines already present are skipped and counted (`3 lines already in the repertoire
were not written again.`). A failure keeps the proposal and names its exact path — `The source PGN changed.
Generated output retained at <manifest>.`, `Publication outcome is uncertain; inspect <manifest> before retrying.`
(never re-appended automatically), `Generated PGN saved to <path>, but the open chapter could not refresh:
<error>`. The PGN commit and the artifact-pointer flip are separate transactions: either can fail alone.
**Cut the result** — `Remove 44 lines` → deletes them from the chapter file; re-running the build is the only
way back.
**Planner walk** — `Plan the lines…` (refused with `A build is already running — let it finish or stop it first.`
or `Load evaluation preferences in Settings before planning.`) → starting lines, source, then the question loop.
`Create 7 & generate` creates every chapter file up front, then queues one ordinary build per build point, each an
ordinary job; a clash becomes `Najdorf (2)` and a failed chapter does not stop the rest. The queue outlives the
route.
**Recover** — inspect, or `Export original file…`, which never replaces a destination, never adopts analysis and
never resumes: `Automatic resume is unavailable: this unfinished build has no verifiable source revision.`

## Data
- The chapter's own `.pgn` is the only file a publish edits, and it is only ever appended to. Games carry
  `Annotator` `Chess Auto Prep`, `Result` `*`, chapter and variation names as `White` / `Black`, `ECO`, `CumProb`.
- Everything stages beside the chapter under `.cap-generation/<chapter>.pgn/`: one `<runId>/` per run with
  `manifest.json`, `course.pgn`, `model_games.pgn` and, once committed, a `published.json` receipt; one
  `artifacts-<id>/` per bundle with `tree.json`, `probes.json`, `traps.json`, `partial.json` and its manifest; and
  one revision-checked `artifacts.current.json` naming the selected generation. Writes are create-only: no run is
  overwritten and nothing is collected. `partial.json` is what a resume reads; the older `<chapter>_tree.json`
  sidecars still load. Each run also dumps `Documents/repertoire_debug_runs/`, newest 10 kept.
- Comments carry machine tokens the app parses and strips, all four groups off by default: `[%eval +0.31]`,
  `[%expectimax +0.42]` (a centipawn equivalent, not a probability), `[%score 46.4%]`, `[%ease 0.62]`, `[%myEase
  0.71]`, `[%games 812]`, `[%lastPlayed 2024]`, `[%onlyMove]`, `[%transposes e4 c5 Nf3]`, one of
  `[%maiaProbability]` / `[%humanFrequency]` / `[%engineReply]` / `[%chessDbMove]`, plus `[%cumProb 12.529%]` and
  `[%loss 0.62]`. Generation never writes `[%pv]` or `[%clk]` but must preserve them; all survive a round trip.
- Shared reads: `eval_cache.db` (Stockfish evals and Maia policy, shared with the audit and hole hunt),
  `master_games.db` (TWIC), the ChessDB dump or slice, the Lichess eval store and the bundled ECO tables. Engine
  depth defaults to **14**; threads, hash and workers come from the app-wide engine settings.
- The planner reads the user's own games from the Player analysis corpora per account, counting only games with
  the repertoire's colour over their first 40 plies, and writes one chapter file per planned chapter.
- A resume needs the same root, side, engine depth, engine-loss limit, opponent rating, master-target setting and
  book source; the horizon may grow but not shrink. See [ALGORITHM.md](../../ALGORITHM.md) for what the search
  optimizes and what each knob means.

## Keep / Change / Drop
Keep — every item under Screen and Actions (27 items), read against the decisions below.

Quirks to rule on: four build sources share one form, so most knobs never apply to the chosen one; the search
starts from the board rather than the chapter root; a modal overlay blocks the whole tab for a run that can last
hours; cancelling needs no confirmation but discarding does; the result is appended automatically with no preview
and no diff, and the only undo is a destructive line cut; a preset can carry an invalid value that blocks Start
with no field to correct; the form's engine-loss default (30) differs from the model's own (50); a failed
download or verification pass is silent; nothing under `.cap-generation/` is cleaned up.

## Decisions (owner, 2026-09-21)
- **Stubbed for now.** `Fill gaps from here…` is a disabled entry in the Actions menu so the menu
  has its final shape; the expectimax search is rewritten later, from ALGORITHM.md, with the UI
  right first. The launch panel, when it comes, has three knobs — opponent rating, how deep, cover
  one in N games — plus a `Prefer traps` toggle, and a source of `Engine + human model` or `ChessDB
  mainline book`. No Advanced sections, presets, Results tab, Jobs pane or planner route.
- **The planner is the Replies tab** (`repertoires.md`): Next gap is the question loop, and the moves
  the user answered by hand are the pins the search keeps.
- **A run never writes into the chapter.** It writes a chapter with `// Draft` in its heading beside
  the one it was started from; the outline shows it as `Proposed`, its lines are read and edited in
  the same workspace, and the user drags the ones they want onto the real chapter. Near-copies fold
  into their host as variations first (the line-diversity bar); the hundred most-reached lines are
  what the user sees first. Deleting the draft chapter is discarding the run.
- **One run at a time**, no lock on the screen: the engine pane is paused while it runs and says so;
  a second run is refused until the first ends.
- **Trick lines** are lines, not flags: our moves, a reply the opponent plays at least 20% of the
  time that loses at least 50 cp, our punishment to the final position (the October 2025 greedy
  finder's rule). They appear under a `Tricks` chip in the outline, full line in mono with the
  blunder marked `?`, with a hover board of the final position, and are accepted like any line.
- Retained run directories, the model-games sidecars and the `.cap-generation/` layout are the old
  app's; whether v2 keeps them is decided when the search is built.

## Decisions (owner, 2026-09-22)
- **The launch is one small dialog** from `Fill gaps from here…`: opponent rating, how deep, cover
  one in N games, `Prefer traps`, and the source (`Engine + human model` / `ChessDB mainline book`),
  with one filled `Fill` button. The run reports as one line in the reading card while the engine
  pane says it is paused; there is no overlay, results tab or jobs pane.
- **The run writes its values into the draft.** Every move of the draft chapter carries
  `[%expectimax]` and `[%score]` in its comment, which is what the Replies tab's expectimax
  column reads (`repertoires.md`). The tree file stays under `.cap-generation/` for a later run to
  extend; it is not what the UI reads.
- **The search core exists** (`lib/v2/chess/generation/`, oracle-tested against the old app).
  What the step builds is the wiring: a Stockfish evaluation source with the shared eval cache,
  the run off the UI isolate, progress and cancel, and the draft-chapter writer.

## What was built (2026-09-22)
- **The dialog** asks `Opponent rating`, `How deep (half-moves)` (default 8, 1–64) and `Cover
  replies met once in`, prefilled from the Replies settings, over the one source line `Engine +
  human model`, and one filled `Fill`. `Prefer traps` came the same evening (below).
- **The run** starts from the board for the chapter's side. The chapter's own moves are pins: at a
  position the chapter answers, only its moves are enumerated. Stockfish scores every position at
  depth 14, loss window 50 cp, through `eval_cache.db` in the support folder — the old app's file
  and schema, so a verdict either app has is not asked for again. Maia-3 at the chosen rating is
  the opponent. `Cover replies met once in N` is a second horizon: a reply reached less than `1/N`
  of the way from the board is valued where it stands and never answered, so a deep fill costs
  what the likely lines cost. One run at a time; a second is refused with `A fill is already
  running.` The engine pane reads `Paused while filling gaps` and follows the board again after.
- **The card** shows one line under the engine bar: `Filling gaps · depth 3/8 · 412 positions` with
  `Cancel` (immediate: the engine is let go and nothing is written), then `Proposed 8 lines in Main
  (draft)` or the failure in the error colour, with a cross to dismiss it.
- **The draft** is `<chapter> (draft)` beside the chapter (then `(draft 2)`, …), `// Draft` under
  its name so the outline says `Proposed`. Its lines are rooted at the chapter's root through the
  chapter's moves to the board, so each can be dragged into the chapter. One game per line the
  search answered, most reached first, at most 100; a near-copy of a kept line (the old diversity
  bar: over 70% shared decisions, or under 25% new) hangs off it as a sideline of at most six
  plies, or is dropped; a line whose every move of ours the chapter already plays is left out. A
  search that proposes nothing new is a failure, not an empty draft. Every move carries
  `[%expectimax +0.42]` (the centipawn equivalent of the search's expected score) and
  `[%score 53.8%]`; a line's first move carries `[%cumProb 29.3%]` and its game `[CumProb]`.
- **The tree** is kept as a v4 `tree.json` under `.cap-generation/<chapter>.pgn/v2-<stamp>/`,
  create-only, for a later run; nothing reads it yet.
- **The Replies tab** at our move shows each candidate's `[%expectimax]` from the open document or
  `not in tree`; nothing is computed while browsing.
- Not built: resuming a kept tree, ChessDB as a source, the old planner route, the
  outline's `Tricks` chip (trick lines are built since the evening, see below).

## Analysis board, traps and the Prep tab (2026-09-22, evening)
The owner asked for lila's analysis board: search from a line without making or opening a
repertoire, find lines *and* traps, and walk through what was found. Built as:

- **The analysis board** (`workspace.md`) is where a search can start without a file:
  Actions ▸ `Generate from here…` or Ctrl+G asks the same dialog, titled `Generate from
  here` with a `Generate` button, and plays for the side at the bottom of the board (flip
  with F). Nothing on the board is pinned: it is a scratchpad. Nothing is written to disk.
  On a chapter the entry keeps its name, `Fill gaps from here…`, and Ctrl+G opens it too.
- **`Prefer traps`** is the dialog's one switch: our moves up to 150 cp worse than the
  engine's best are tried (50 cp otherwise), so the expectimax value can pick a line whose
  point is the opponent's likely mistake. The dialog ends `Engine + human model · for White`.
- **Traps** come from every run, with or without the switch, read off the search tree the
  run built (`chess/generation/traps.dart`, no extra engine time): at each opponent position
  on our chosen lines, a reply played at least 20% of the time that loses at least 50 cp
  against their best reply there, with our answer after it (our chosen move, then their
  likeliest reply, up to six plies; empty when the search stopped at the mistake). One
  trap per position after the mistake; ranked by how often it springs from the board times
  what it loses, capped at 3 pawns. On a chapter run the trap lines are written into the
  draft after its lines, unless a kept line already walks them.
- **The Prep tab** (reading card, open by default outside Tactics) lists the last run:
  `Traps · n` then `Lines · n`. A trap row reads `5...Nxe4? 6.Bxf7+ Kxf7` (the mistake in
  ink, our answer muted) over `after 1.e4 e5 … · played 34% · loses 1.8 · 1 game in 9`; a
  line row is its numbered moves over `1 game in 4 · +0.42`. Hovering floats the position,
  a click puts it on the board, ↑ / ↓ walk the rows while the tab is up. A board run's row
  is played onto the analysis board (existing moves followed, new ones added as
  variations) and a trap stops on the mistake, the answer one → away; a chapter run's row
  opens the draft in the builder there. Before any run the tab says what a search does;
  its strip control is `Generate…`. A failure is said once, on the fill line.
- **Finish now** sits beside `Cancel` on the fill line: the search stops after the
  expansion under way and the tree as it stands is read. The search goes level by level,
  so an early finish is every line to the depth reached — the way to use a deep search
  when in a rush (depth 8 at engine depth 14 runs at about a thousand positions a minute).

## The Search tab: values, not lines (owner, 2026-09-23)
The owner found the Prep flow confusing ("why is it so confusing?"): a dialog, `Generate`,
`Finish now` and `Cancel` as text links, a `Prefer traps` switch, and results that went
straight to lines and traps. Their rule: *a search gets the evals; once there are evals, lines
are trivial — do not go straight to lines*. Supersedes the two sections above where they differ.

- **Search is a tab**, `Search` (was `Prep`), with no dialog. On top: `Opponent` (the Replies
  rating, written back to settings), `Depth` (half-moves, default 8, kept for the window's
  life), `Skip under 1 in` (the cover rule, also shared) and one filled `Search` button, which
  becomes `Stop` while the search runs. Actions ▸ `Search from here` and Ctrl+G bring the tab
  up and start it with the same numbers, anywhere a position is on the board and not hidden —
  a read-only file or a game included, since nothing is written.
- **No `Prefer traps`, no pins.** The loss window is always 50 cp; every legal move of ours
  inside it is searched, the chapter's or not. *Superseded the same day by the section below:
  nothing is pruned.*
- **The table follows the board.** Under a status line (`Searching for White · depth 3 of 8 ·
  406 positions`, then `Searched …` or `Stopped at depth 3 …`), the position on the board is
  looked up in the search tree by the moves from the document's root. At our move: `Your move ·
  Expectimax · Engine`, best first. At theirs: `Their reply · Played · Expectimax · Engine`,
  most played first, a reply losing ≥ 50 cp against their best reply marked `?` (a trap).
  Values are White-relative, as the engine pane's; a move not expanded yet reads `…` in the
  Expectimax column. A click plays the move (into the chapter, as the Explorer's do), a hover
  floats the position. Off the tree: `This position is not in the search.` with `Go to where it
  started` when that line is still in the document.
- **Live.** The search hands the tree out at each new level and every two seconds within one
  (`SearchSnapshot` in `chess/generation/search.dart`), so the first row of values appears as
  soon as the root's moves are scored. `Stop` keeps what it has; nothing else stops a run.
- **Lines are asked for.** After a search on a writable repertoire chapter, for the chapter's
  side, the tab's foot offers `Make lines`, which writes the `<chapter> (draft)` chapter as
  before (diversity bar, traps after the lines, what the chapter plays left out) and then says
  `8 lines in Main (draft)` with `Open`. The v4 tree is still kept under `.cap-generation/`.
- Gone: `fill_dialog.dart`, `prep_pane.dart`, the fill line above the tabs, `showFound`, ↑/↓
  over Prep rows, `FillRequest.preferTraps`, `trapLossLimitCp`.

## Explore, don't prune: the Positions column (owner, 2026-09-23)
The owner wants the search to explore, not prepare: "no pruning etc … the most braindead
approach … build my DB of stuff and find interesting positions" they can click through, in a
column on the left like the old Player analysis positions list, with the PGN on the right.
Supersedes the Search tab section where they differ.

- **Nothing is pruned.** Every legal move of ours (`SearchConfig.lossLimitCp` null) and every
  reply the model gives any weight (no reply floor); `Skip under 1 in` is gone from the tab.
  `Depth` is empty by default (`Any`): the search goes level by level until stopped. While it
  runs, `Stop` keeps what it has and `Stop after depth N` lets the level under way finish
  (`LastPly` in `search.dart`, `StopReason.levelDone`). A typed depth still ends there. A
  tree with no horizon or window is written to v4 as `max_depth` 512 and `max_eval_loss_cp`
  100000 and read back as none.
- **The cost is real.** At engine depth 14 a run scores about 25 positions a second, so from
  a middlegame depth 2 (~1k positions) takes about a minute, depth 3 (~25k) about fifteen,
  depth 4 hours. Cached scores (`eval_cache.db`) make a repeat run over the same positions
  quick. Lichess cloud evals or ChessDB as a score source would cut this; not built.
- **Finds.** When a run stops, `findsOf` (`chess/generation/finds.dart`) reads the tree —
  every move of ours followed — for four kinds, at no engine cost: *trap* (a reply played
  ≥ 20% that loses ≥ 50 cp against their best, leaving us level or better and ≥ 50 cp better
  than our best move at our last turn, so a reply that only fails to punish a bad move of ours
  is not one), *only move* (one move of ours holds, the rest lose ≥ 150 cp, from −150 up to
  +300), *their only move* (one reply holds for them, the rest lose ≥ 150 cp, found < 50%)
  and *practical* (the move worth most against the model is ≥ 30 cp worse for the engine and
  ≥ 0.02 better in expected score). A find's rank is how often a game gets there times what
  is at stake, divided by one plus the pawns our own moves gave up on the way; past three
  pawns the find is left out. At most 1000 per run.
- **Kept globally.** `finds.db` in the support folder (`storage/finds_store.dart`), one row
  per kind, side and position: found again, replaced by the newer finding. Each keeps its line
  from the document's root, the ply of the position, the key move, the scores, the rating and
  when. Opened on first use.
- **The Positions column.** `Positions` in the top bar (Ctrl+P, also in Actions) swaps the
  list column's content for the finds, in every mode with a list; pressed again it gives the
  mode's list back. `Top | Often | New` orders them, a typeable `Kind` field narrows to one
  kind. A row reads `4.d4 Bc5?  Trap` over `played 29%, loses 1.7 · 1 in 3 · as White`; hover
  floats the position, `⋯ ▸ Remove` forgets it. A click (or ↑/↓ while the column is up) puts
  the whole line on a new analysis board at the position, seen from the side searched for, so
  the move list, engine and Search tab read it as any line and it can be played on or saved.
  The Search tab's status says `… · 4 found, listed in Positions (Ctrl+P)`.
- Owner-facing open items: whether finds from a sharper, deeper search are the right ones;
  a score source faster than depth-14 Stockfish; whether the column should also list other
  result sets (My games mistakes, TWIC scan hits) through the same `FindsPanel` shape.
