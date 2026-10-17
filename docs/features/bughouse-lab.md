# Bughouse lab

A scratch table for two-board bughouse. The player sets a position up (from the
start, by playing, from FENs or a dual FEN) and sees every legal move on each
board scored for a chosen clock case, from the precomputed Hivemind book or,
with the engine switched on, from a live Hivemind search that is then saved to
the book. It also shows what the FICS archive played, ranks practical moves by
bughouse expectimax, and plays Hivemind-vs-Hivemind matches from the table.

Code: `lib/features/bughouse/` (`BughouseLab` table owner, `TableSearch`,
`ArchiveMoves`, `BughouseExpectimaxSearch`, `Matches` + `MatchRunner`, screen
and panels), plus `lib/chess/bughouse/` (table, line, setup, BPGN, Hivemind
score scale, match model, expectimax), `lib/storage/bughouse_books.dart`,
`lib/storage/hivemind_write.dart`, `lib/storage/bughouse_matches.dart`,
`lib/storage/bughouse_expectimax.dart`, `lib/engines/hivemind_engine.dart`,
`lib/engines/hivemind_install.dart`, `lib/engines/crazyara_engine.dart`,
`lib/engines/bughouse_backend.dart`, `lib/app/bughouse_view.dart` (`BughouseView`),
`lib/app/self_test.dart`. Engine internals: [Hivemind](../HIVEMIND.md);
expectimax algorithm: [ALGORITHM.md](../ALGORITHM.md#bughouse-expectimax).

## Screen

`Bughouse lab` in the mode menu (`Data & engines`), listed only when the build
carries the engine assets. Entering pauses the workspace's Stockfish (`Paused
while the Bughouse lab is open`). Left column: both boards; right column (up to
480 px): the analysis panel, or Matches.

- **Boards** — board 1 has A (White) and C (Black), board 2 D (White) and B
  (Black); teams A + B and C + D. A + B's colour is at the bottom of both
  boards unless flipped. Each board is 200–480 px, sized to the window; the
  column scrolls when it needs more height. Last move marked; pieces move by
  click or drag. Clicking a board makes it the one the keys step.
- **Seat rows** — turn dot (`White to move`), seat letter, then five fixed
  reserve slots (P N B R Q). Empty slots are faint; held pieces show a count.
  Only the player on move can drop: click the piece (legal squares ringed) then
  a square, or drag it. Tooltips explain the waiting state.
- **Move list** — under each board its own moves numbered as that board
  counts them, the current move marked; click to go there. Step buttons `First
  move`, `Back`, `Forward`, `Last move`. Empty: `No moves yet`.
- **FICS archive** — under each board when `bughouse_book.db` is present:
  `FICS games · <n>` (tooltip: years, recorded games not engine analysis,
  results for the team playing the move), then up to 6 moves on that board,
  most played first: `Move`, `Games`, a `Won / drawn / lost` bar (tooltip:
  average rating and unfinished games). Empty: `No archived game reached this
  position.`, `Past the archive’s <n> plies.`, `No move here was played in <n>
  games or more.`; failure: `The FICS archive could not be read: …`.
- **Edit position / FEN** — collapsed fold under the boards: per board `Board
  N FEN` and one reserve box per player (`Player A’s reserve`), filled from
  the table; a live `Pieces outstanding: …` / `Too many: …` line; `Set
  position`. A dual FEN pasted into either FEN box fills both.
- **Panel switch** — `Expectimax` | `Engine analysis`.
- **Engine analysis** — `Time` chips `A + B may sit` / `Even` / `C + D may
  sit` (tooltips explain each); engine switch (`Toggle engine (E)`) with
  `Hivemind`, or why it stopped in the error colour; `Saved scores · <root> /
  <reply> nodes` when the book answered, opening `Saved analysis` (engine,
  searches, clock, completion time, engine and network SHA-256, calibration
  note); while on, the joint lines (below); a status line only when there is
  something to say; then the two move tables.
- **Joint lines** — two halves, A B then C D: each team's score in its header
  and up to three joint actions, one column per seat (`sits` where it sits,
  blank when not on move). Header tooltip: whether the zero was measured or
  assumed, and `Hivemind’s scale, not pawns.` Placeholder rows: `Thinking…` or
  `Waiting for turn`.
- **Move tables** — one per board, side by side: header `Board 1 · A` and
  `Score` (tooltip: Hivemind's scale, 0.00 level, + good for the mover), then
  every legal move including drops, scored ones best first for the mover (the
  best bold), unscored ones `—` after them by SAN. A row's tooltip is the line
  after the move.
- **Expectimax** — `Expectimax` button (`Stop` while running), `Board 1` /
  `Board 2`, a fold `<plies> plies · <nodes> Hivemind nodes` with `Search
  plies` (2–4, default 2) and `Hivemind nodes` (100–30000, default 800); notes
  `<board> · no clocks or sitting`, `White / Black expectimax · scores from
  White’s side.`, `Partner board fixed; captures still feed its pockets.`; a
  status line; a table `Move`, `Played`, `Eval`, `Exp W`, `Exp B` (tooltips
  define each); the selected move's replies with `Play move`.
- **Matches** — `Actions → Matches` replaces the panel (`Back to analysis`
  returns): `New match` (while one runs: `Playing game 4 of 10`, `Follow the
  game being played`, `Stop`), the history (`<score> · <status>`, statuses
  `Not started`, `Running`, `Completed`, `Stopped`, `Failed`), then the chosen
  match: `White on board 1 scored 5½/10 (55% ± 27) · 5W 1D 4L`, what was left
  out (`1 unfinished, not counted`, `… drawn at the move limit or by both teams
  sitting`), the opening (or `From the start`) with `Show`, `Resume`, `Delete`,
  and its games (`#`, `White on board 1`, `Black on board 1`, result, ending).
  Empty: `No matches yet. Set a position up on the boards, then play it out.`

## Actions

**Play a move or drop** — on a board, a table row, an archive row, a joint
line or `Play move` → joins that board's line after what is shown; a capture
goes to the partner's reserve. Refusals in the status line: `That drop is not
legal.`, `It is not black’s turn on board 2.`, `<uci> is not legal here.`,
`That line no longer fits the position.`
**Step a board** — its list, its buttons, or ← → Home End for the focused board
(a text box keeps those keys). Only that board moves; refused with `Can’t step
there: <san> on board 2 would have no piece to drop.`
**Set a position** — `Set position` → both boards from the boxes as a new line;
problems under that board's boxes, e.g. `A king can’t be in reserve (N is the
knight).`, `A FEN has 8 ranks; this has 7.`, `That leaves an impossible
position.`, `That is not a valid dual FEN.`
**Point at a row** — a table, line, archive or expectimax row draws its move
(an arrow, or a faint piece for a drop) on its board until the pointer leaves.
**Read the scores** — the book's for the chosen clock, at once. Otherwise moves
read `—` until the engine is on.
**Engine switch** (E, or `Toggle engine`) — the lab's one Hivemind runs only
while on and while the mode is on screen. It searches each team with a move at
800 nodes for the joint lines. If the book lacks the position for this clock,
it then fills the tables: each team searched (800 nodes, 8 lines) for the zero
and move order, then every legal move of both boards played, the engine's own
first moves first, and the answering team searched (800 nodes) — `Scored n of
total moves` as it goes. The finished table is saved to the book (`Saving
analysis…` → `Analysis saved`). A new position or clock restarts; off cuts the
search short. Session results are remembered; leaving the mode quits the engine.
**Failed analysis save** — `Analysis not saved: …` with `Retry save` (the exact
entry, no re-search) and `Discard saves` (confirm: stop retrying all failed
analysis saves, including earlier positions; saved data stays). Pending saves
outlive the panel through the app's pending writes. An unreadable book: `The
database could not be read: …`.
**Expectimax** — `Expectimax` → loads a saved result for the position, board,
plies and nodes, else starts CrazyAra (policy) and a 2-core Hivemind (values),
streams rows (`<n> / <total> moves · <p> positions`), and saves the complete
result (`Complete · …`). `Stop` keeps partial rows (`Stopped · …`); a board
edit stops and clears it; `Position limit reached` at 10,000 positions.
Without CrazyAra: `CrazyAra is not installed. See the Bughouse Lab setup
guide.` Switching to Expectimax turns the engine switch off.
**Run a match** — `New match` dialog: `Name` (default `Bughouse match`), `The
boards` / `A dual FEN`, `Games` (1–1000, 10), `Hivemind A thinks (nodes)` and
`Hivemind B thinks (nodes)` (50–1,000,000, 800), `Draw after (half-moves)`
(20–2000, 240), `Swap seats every other game` (on), the three clock chips
(default the lab's) → `Play 10 games`. Bad start: `That is not a position yet
— check the moves or the FEN.` A match runs on its own Hivemind; teams are
asked in turn, A + B first. For the first 8 moves a team plays a move drawn
from the engine's top 3 within 0.05 Q of the best, seeded `seed + game`. A game
ends when a team on move has no legal joint action, at the ply limit (draw),
after four joint actions in a row that sit on every board (draw), or on engine
failure (`The match stopped: …`). Each game is saved as it ends.
**Read a run** — click a history row; `Show` puts the opening on the boards; a
game row shows that game at its end; `Follow the game being played` makes the
boards follow the live game while the tables rest.
**Stop / Resume** — `Stop` drops the game in flight; `Resume` (stopped, failed
or unstarted with games left) reads the match from disk and plays on from it.
**Failed match save** — further games stop; `Retry save` saves the same
checkpoint without replaying; `Discard save` (confirmed) reloads saved results
and leaves files on disk. New match, Resume and Delete wait for it. Other
failures: `Could not create the match directory: …`, `Could not save the
match: …`, `Could not read the matches: …`, `Could not read <folders>; left on
disk untouched.` with `Retry`.
**Delete a match** — `Delete this match?` / `<name> goes to
bughouse_matches/.trash.` → `Could not delete the match: …` on failure.
**Actions menu** — `Toggle engine`, `New game` (start position, clock kept),
`Flip boards`, `Matches` / `Back to analysis`, `Copy dual FEN`, `Paste dual
FEN`, `Copy moves`, `Paste moves`. Moves are BPGN movetext in played order
(`1A. e4 1B. d4 1a. e5`), after `[SetUpDualFEN "…"]` for a set-up start; a
paste takes that or a FICS game and is refused whole (`Not pasted: <token> does
not play.`, `No bughouse moves to paste.`). The window's paste commands are
refused here with `The Bughouse lab pastes from Actions: Paste dual FEN or
Paste moves.`

## Data

- **Engine** — `hivemind` (~3.7 MB), ONNX Runtime (~28 MB), `hivemind.onnx`
  (~54 MB) from `assets/bughouse/`, installed into `<support>/bughouse/` and
  checked against `manifest.json` (size, SHA-256) before every launch; a
  mismatch is rewritten via a `.part` file. Windows: the VC++ DLLs from
  `data/bughouse-runtime/` are copied in the same way, the engine's PATH is its
  folder plus System32, and exits `0xC0000135`, `0xC000007B`, `0xC000001D` are
  explained. Options: half the machine's cores, `Hash` 256, `BatchSize` 8.
  `--self-test-bughouse=<report.json>` installs, starts and queries the engine
  as the lab does and exits 0 on success; `tools/windows_self_test.ps1` and
  `.github/workflows/windows-check.yml` (pushes to `windows-check`, Server
  2022 and 2025) run it.
- **Score** — Hivemind prints `180·tan(1.56·Q)`. The lab re-centres in Q: offset
  `(q_A+B + q_C+D) / 2` from both teams' searches, or the level-table offset
  (±0.5814 per team's sit bit) when one team has no move. 0.00 is level; the
  book stores the same scale. Not pawns.
- **Hivemind book** — `hivemind_book.db` (`tools/bughouse_db/hivemind_book.py`
  schema). Looked for under `$BUGHOUSE_DB_HOME` alone when set, else
  `~/.local/share/chess-prep/bughouse-db/`, then the support folder. Key:
  64-bit FNV-1a of each board's four FEN fields, reserve in `KQRBNP` order,
  joined by ` | ` (`tools/bughouse_db/poskey.py`). Scores are A + B's per
  clock (`ahead`/`even`/`behind`); a book without the `seats` meta row is read
  with B and C swapped. A position counts when it is `done` or has move rows.
  Lab saves keep the builder's queue status and priority. Each completed clock
  appends to `analysis_history` (scores, PVs, calibration, engine name and
  hashes, budgets, reported nodes/depth) and `current_analysis` points at the
  shown run; older scores are archived with an unknown engine identity.
- **FICS archive** — read-only `bughouse_book.db` in the same places, same key,
  results team-relative.
- **Expectimax book** — `bughouse_expectimax.db` in the same places: tables
  `analysis` (complete results per position, board, profile) and `evaluation`
  (cached Hivemind values). CrazyAra is found via `$CRAZYARA_BIN`,
  `<support>/crazyara/crazyara` or `~/.local/share/chess-prep/crazyara/`
  (`tools/setup_crazyara.py`, Linux x86-64).
- **Matches** — `Documents/bughouse_matches/<name-slug>/`: `match.json`
  (version 1; config with `participants`, `timeStance` ahead/level/behind,
  `variety`, `seed`; games as board-digit UCI `1e2e4`, `2P@f7`) is the
  authority; `games.bpgn` (seat tags, `SetUpDualFEN`, `1A. e4 1B. d4`) is a
  derived export, repaired when it differs, a write failure only logged. Saves,
  repairs and deletes take a per-match lock; encoding runs off the UI isolate.
  An unreadable or newer `match.json` is left out and named, untouched. A run
  left `running` reads as stopped. Delete moves the folder to `.trash`.
  BPGN is bughouse-db.org's format (`tools/bughouse_db/bpgn.py` parses it):
  the board letter's case names the mover's colour, moves are in played order,
  and `1-0` is a win for the pair holding White on board 1, so match games can
  be indexed like FICS games. `SetUpDualFEN` is non-standard but needed to
  replay a set-up start.
- **Why matches sample** — at match budgets Hivemind's answer does not wobble
  enough to change the move, so without the opening sample a ten-game match is
  one game ten times. Sampling only from the engine's own top lines within
  0.05 Q (Q, not the printed score, which cannot be subtracted on) makes every
  divergence a move the engine ranks. Nodes plus a stored seed usually replay a
  game; the search is not bit-exact, so one flip can diverge the rest.
- **Clock stance is fixed per match, not simulated** — teams take turns in
  this model, so a simulated diagonal clock would never move; the stance is the
  one bit the engine reads and decides whether sitting is legal at all. The
  headline counts White on board 1 every game, whoever sits there: the score of
  the line, not of the two teams.
- **Backup** — checksummed gzip snapshots of both books in
  `data/bughouse-books/`; restore with `tools/bughouse_db/snapshot.py` (see
  its [README](../../data/bughouse-books/README.md)).
- The table itself is never saved: leaving the mode keeps it for the session.

## Owner decisions

- One engine, and it fills the database: the lab reads the precomputed book and
  the engine switch scores and adds what is missing (owner, 2026-09-24).
- The FICS archive shows under each board whenever the file is on the machine
  (owner, 2026-09-24).
- The three `Time` chips are the only clock question; Compare clock scenarios,
  editable clocks, Our team, Must move on and Search are dropped (2026-09-23).
- No engine settings rows: Hivemind takes half the cores, 256 MB, batch 8
  (2026-09-23).
- Matches live inside the lab, on their own Hivemind; `Stop` drops the game in
  flight and `Resume` replays it with the same per-game seed (2026-09-23).
- Expectimax values are computed only on `Expectimax`; browsing shows stored
  results (AGENTS.md rule).

## Not built

- The CrazyAra "Bughouse Lab setup guide" named by the error: no such guide
  exists in `docs/`; install notes live only in `docs/ALGORITHM.md` and
  `tools/setup_crazyara.py`.
- Match crosstable or per-team settings block: `match_panel.dart` shows the
  opening score only.
- Typed-line match start: `new_match_dialog.dart` offers only `The boards` and
  `A dual FEN`.
