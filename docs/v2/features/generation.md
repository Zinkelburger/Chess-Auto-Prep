# Generation

Status: corrected by the owner (2026-09-21: decisions below; not built)
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
