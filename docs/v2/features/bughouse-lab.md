# Bughouse lab

Status: built 2026-09-23; usability and analysis provenance revised 2026-09-24 at the owner’s request
Old code (oracle only): `lib/features/bughouse/`, `tools/bughouse_db/`, `tools/mcp/bughouse/`
Web pages it follows: `python/twic-position-finder/frontend/src/pages/bughouse.astro`, `bughousedb.astro`
Plan step: 12

## Purpose
A bughouse player sets a two-board position up — from the start, by playing, or from a FEN per board —
and sees every legal move on each board scored for the clock situation they choose: from the precomputed
Hivemind book when the position is in it, from a live Hivemind search when it is not. They can ask the
engine switch on to see each team's best joint actions over both boards, and see what the FICS archive played on
each board.

## Screen
Reached from the mode menu as `Bughouse lab`; the entry is left out when the build carries no engine.
One screen: the two boards and their FICS continuations on the left, compact engine tables on the right.
The board column scrolls when the archive or expanded editor needs more height.

- **Boards** — board 1 has A (White) and C (Black), board 2 D (White) and B (Black); teams A + B and C + D.
  A + B's colour is at the bottom of both boards until `Flip boards` (Actions menu). Each board is as large as the window
  allows (200–480 px), the last move marked, a move played by click or drag.
- **Seat rows** — player letter and turn dot, then five fixed reserve slots (pawn, knight, bishop,
  rook, queen). Empty slots are faint; held pieces retain full contrast and show their count, including
  one. Only the player on move can click or drag a held piece. Clicking selects it, highlights legal
  drop squares, and clicking a square plays the drop; selecting again cancels. Turn changes invalidate
  the selection. Tooltips explain click/drop and waiting-for-turn states.
- **Move list** — under each board its own moves, numbered as that board counts them (`1. e4 d5`), the
  current one marked, the ones stepped back past faint; click one to go there. Four step buttons under it.
- **Setup boxes** — collapsed by default under `Edit position / FEN`; per board a FEN box and one reserve box per player (`A`, `C`; `D`, `B`), filled from
  the table as it is played; `Set position` under both boards and a live `Pieces outstanding: …` line
  (`Too many: …` for extras). A dual FEN pasted into either FEN box fills both boards.
- **Engine bar** — the engine switch (`Toggle engine (E)`) as in the other modes, and beside it `Engine`,
  `Hivemind · thinking 4 s a team`, `Hivemind` once the longest pass is shown, or why it stopped, in the
  error colour.
- **Time chips** — `A + B may sit` / `Even` / `C + D may sit`, Even first, each with its one-line tooltip.
  The only question the lab asks.
- **Engine** — the switch and `Hivemind` (or why it stopped, in the error colour). While on, a column per
  seat, `A` `B` then `C` `D`: each team's three best joint actions across its two columns (`sits` where
  it sits, empty where it is not on move) with the score beside them, the team's score in its header.
  Compact striped rows show available lines without reserving three empty rows. The score’s tooltip
  explains calibration. `Saved scores` opens the saved engine identity, node budgets and date.
- **Status line** — shown when reporting progress, save status or a problem: `Scored n of total moves`,
  `Saving analysis…`, or `Analysis saved`. A refused action, unreadable database or `Analysis not saved: …`
  uses the error colour; a failed save offers `Retry save`.
- **Move tables** — one per board side by side, a plain rule between them: shaded header names the board, mover (`D`) and `Score`, then
  every legal move on that board, drops included, with its score for the chosen `Time`, read from the
  mover's side, best first and bold; unscored moves `—` below by SAN. The score's tooltip is the line after
  the move. The `Score` header's tooltip says it is Hivemind's scale, not pawns.
- **FICS archive** — below each actual board and its move navigation: `FICS games · {games}`
  (the years in its tooltip) and up to 6 continuations on that board, most played first: seat and SAN
  (`D exd5`), games, and a won / drawn / lost bar for the team that played it (average rating and
  unfinished games in the tooltip). Empty: `No archived game reached this position.`, `Past the archive’s
  {plies} plies.`, or `No move here was played in {n} games or more.`
- **Matches** — hidden from the default workspace; Actions → Matches opens them, Actions → Back to
  analysis returns to scores. There is no Tables/Matches switch.
- **Matches** — `New match` (while one runs: `Playing game 4 of 10`, `Follow the game being played`,
  `Stop`); the history, four rows tall, newest first, each with its score and state (`5½/10 · Completed`);
  then the match chosen: `White on board 1 scored 5½/10 (55% ± 27) · 5W 1D 4L`, what was left out (`1
  unfinished, not counted`, drawn at the move limit or by both teams sitting), the opening with `Show`,
  `Resume` for a stopped, failed or never-started match with games still to play, `Delete`; and its games, `#`, `White on
  board 1`, `Black on board 1`, result and ending. Empty: `No matches yet. Set a position up on the boards,
  then play it out.`

## Actions
**Play a move or a drop** — on a board, a table row or an archive row → it joins that board's list after
whatever is on the boards, a capture is credited to the partner's reserve, the tables update → `That drop is
not legal.`, `It is not black’s turn on board 2.`, `{uci} is not legal here.`
**Step a board** — its list, its buttons, or ← → Home End for the board last played or stepped on (a text
box keeps those keys) → only that board moves → `Can’t step there: P@d5 on board 2 would have no piece to
drop.` when the other board dropped a piece this step would take back.
**Set a position** — `Set position` → both boards from the boxes, a new line → the problem under the
board's boxes: `Player B: A king can’t be in reserve (N is the knight).`, `A FEN has 8 ranks; this has 7.`,
`That leaves an impossible position.`, `That is not a valid dual FEN.`
**Read the scores** — the book's when it has the position for the clock, at once. Otherwise the moves read
`—` until the engine is switched on: then, after its first 1 s pass, it scores the table as the builder
does — each team with a move searched (1500 nodes) for the zero and to order its moves, then every legal
move of both boards played, the likeliest first, and the answering team searched (200 nodes) — the table
filling as it goes, and adds the finished position to the book for that clock (the builder's rows,
status `done`). About two minutes for an opening position on half of an eight-core desktop. Searches are
remembered for the session. After an engine failure, switching it on again starts a fresh engine and
finishes the missing scores. A failed book save keeps the completed entry for `Retry save`, including
after changing positions, leaving the mode, or disposal of its original owner: the app's pending-write
registry retains the frozen analysis and its retry. It is only labelled saved after the database confirms
the write. An accepted write keeps one history ID across retries; an acknowledged historical retry never
replaces a newer current analysis. Unsaved entries remain in memory until SQLite commits; a process crash
before commit still loses that unsaved analysis.
**Read the score** — Hivemind's own scale (`180·tan(1.56·Q)`), re-centred: each team's search of the
position gives the offset, `(q_A+B + q_C+D) / 2`, taken off in Q; when a team has no move the level-table
offset stands in. 0.00 is level. The book stores the same scale.
**Engine switch** — the lab's one Hivemind runs only while it is on. Each team with a move searched with
its clock bit for 1 s, then (after the table is scored, when the book lacked it) 2, 4, 8, 16 and 30 s a
team, the lines shown as each pass ends. Zero from both
teams' searches, or assumed when one has no move. A new position or clock starts again from 1 s; off cuts
the pass short → the reason in the engine bar, and the switch goes off.
**Point at a row** — a table, analysis or archive row draws its move as an arrow (a drop: the piece faint on
its square) on its board; leaving the row takes it away; clicking plays it.
**Run a match** — `New match` → a dialog: name (the line on the boards), `The boards` / `A dual FEN`,
`Games` (1–1000, default 10), `Hivemind A thinks (nodes)` and `Hivemind B thinks (nodes)` (50–1,000,000,
default 800), `Draw after (half-moves)` (default 240), `Swap seats every other game` (on), the three `Time`
chips → `Play 10 games`. A Hivemind of the match's own plays both teams, the teams asked in turn; for the
first 8 joint actions a move is drawn from the engine's top 3 within 0.05 of Q of the best, seeded per
game. A game ends when a team on move has no legal joint action (Hivemind's own rule), at the ply limit
(a draw), after four joint actions in a row that sit on every board (a draw), or when the engine fails.
Each game is written as it ends → `That is not a position yet — check the moves or the FEN.`, `Could not
create the match directory: …`, `Could not save the match: …`, or the engine's reason. A failed
checkpoint stops further games and retains the exact accepted snapshot for `Retry save`. New match,
Resume and Delete wait for that obligation. Retry saves the checkpoint without replaying games; continuing
a stopped run requires Resume. Final completion waits for confirmed engine exit and final publication.
Accepted saves, including final engine shutdown, remain owned by the app after the panel is disposed.
**Read a run** — click a history row; `Show` puts the opening on the boards, a game row puts that game on
them at its end, `Follow the game being played` makes the boards follow the live game while the tables
rest; `Stop` drops the game in flight so `Resume` plays it again (as does a last game the engine failed
in; `Resume` reads the match from disk, so a game the old app added since is kept); `Delete` asks, then
moves the match to
`.trash` → `Could not delete the match: …`
**New game / Flip boards** — the start on both boards, the clock kept / the other colour at the bottom.
**Actions menu** — Toggle engine (E), New game, Flip boards, Matches / Back to analysis, Copy dual FEN, Paste dual FEN.

## Data
- **Engine** — `hivemind` (~3.7 MB on Linux), the ONNX Runtime library (~28 MB) and `hivemind.onnx` (~54 MB)
  from `assets/bughouse/`, installed into `<support>/bughouse/` and checked against `manifest.json` (size
  and SHA-256) before every launch; a mismatch is written again from the asset under a temporary name. On
  Windows the build's VC++ DLLs under `data/bughouse-runtime/` are copied beside it the same way (a build
  without that folder copies the DLLs beside the app instead), the engine's PATH is cut to its own folder
  and System32, and an engine that exits before `uciok` is reported with what its exit code means
  (`0xC0000135`, `0xC000007B`, `0xC000001D`).
  `--self-test-bughouse=<report.json>` makes the app install and start the engine exactly as the lab does,
  in the user's own support folder, ask for one search, write what happened and exit (0 when it answered).
  `tools/windows_self_test.ps1` runs it on any Windows PC; `.github/workflows/windows-check.yml` runs it and
  the rest of the Windows checks on Server 2022 and 2025 when the `windows-check` branch is pushed. Hivemind
  runs on half of the machine's cores, 256 MB hash, batch 8. MIT (aminwoo).
- **Hivemind book** — `hivemind_book.db` (`tools/bughouse_db/hivemind_book.py`), read, and added to by the
  engine switch in the builder's own rows (a new file gets the builder's schema), looked for under
  `$BUGHOUSE_DB_HOME` alone when set, else `~/.local/share/chess-prep/bughouse-db/`, then the support folder.
  Keyed by FNV-1a of each board's four FEN fields with the reserve in `KQRBNP` order, joined by ` | `.
  Scores are A + B's; a book in the old seat lettering (board 1 Black `B`) is read with `B` and `C` swapped.
  Both the v2 writer and Python builder append each completed clock’s exact scores/PVs/calibration to
  `analysis_history`; `current_analysis` identifies the displayed run. Provenance includes the UCI
  engine name, binary/network SHA-256, requested root/reply nodes, reported nodes/depth per search,
  completion time, scoring method and startup settings (desktop) or backend details (Python).
  Before replacement, legacy scores are archived with an explicitly unknown engine identity and the
  available position-level budget/date; those old budgets cannot reliably distinguish clock cases.
  History is local: the website upload still publishes the current score tables only.
- **FICS archive** — read-only `bughouse_book.db` beside it, same key; results team-relative.
- **Matches** — one folder per match under `Documents/bughouse_matches/<id>/`: `match.json` (version 1, the
  old app's keys: config with `participants`, `timeStance` ahead/level/behind, `variety`, `seed`; every game
  with its board-digit UCI moves `1e2e4`, `2P@f7`) and `games.bpgn` (four seat tags, `SetUpDualFEN` for a
  set-up start, movetext `1A. e4 1B. d4 1a. e5` in the order played). Both apps list and read the same
  folders; a run either app left `running` reads as stopped. JSON is authoritative; BPGN is a disposable,
  deterministic export. V2 reopens supported, valid JSON under the per-match lock and repairs a missing
  or differing export. It never repairs from invalid/newer metadata or through unreadable/linked files
  or an unverified staged file. Unreadable metadata or a failed repair leaves the previous history visible with Retry. An integrity inspection only
  compares the two files and does not repair them. V1 does not perform this repair, so an interrupted v2
  export can remain stale until v2 reopens it. V2 save, repair and delete share a per-match lock; the v1
  match writer does not take that lock, so this does not promise safe simultaneous cross-app editing.
  Deleting moves the folder to `.trash`. Match JSON/BPGN formats are unchanged.
- **Git backup** — consistent, checksummed snapshots of both books live in `data/bughouse-books/` as
  gzip chunks below the host’s file limit. The backup includes committed WAL data. Restore into an empty
  directory using `tools/bughouse_db/snapshot.py`; see [backup instructions](../../../data/bughouse-books/README.md).
- **Nothing else is written.** The lab is a scratchpad: leaving the mode keeps the table for the session,
  quitting loses it.

## Keep / Change / Drop
Keep — Boards
Keep — Seat rows (Change: plain dot and `Player A`, reserve only as held pieces, from the web page)
Keep — Move list (Change: per board, each board steps on its own, from the web page)
Change — Setup boxes replace the Edit position panel (FEN and reserve per board, pieces outstanding)
Change — Time chips replace the Board tab (Our team, Must move on and Search dropped 2026-09-23 by the owner)
Change — Move tables replace the Engine tab's lines (every legal move scored, from the book or by the engine into the book)
Keep — Engine switch (Change 2026-09-23: continuous passes for both teams, like the engine bar elsewhere,
replacing a one-shot Analyze)
Keep — Read the score (measured, or assumed when a team has no move; no carried zero)
Keep — FICS archive (under each actual board, always shown when present)
Keep — Point at a row, Play a move or a drop, Step a board, Set a position
Drop — Score header, Engine settings tab, editable clocks, Use the board clocks, Compare clock scenarios
Keep — Engine tournament panel, as Matches in Actions (Change: no crosstable or
settings block; `A line` start dropped — play it on the boards; stop drops the game in flight; Resume added)
Keep — Run a match, Read a run

## Decisions (2026-09-23, made without the owner)
- The board remains a scratchpad; completed analysis is saved in the Hivemind book, and match games
  in their match folders.
- Matches stay inside the lab, on a Hivemind of their own so the tables keep theirs; same folders and
  format as the old app. `Stop` drops the game in flight rather than keeping it unfinished, so `Resume`
  (new) replays it; seeds are per game so a resumed match samples as it would have.
- The desktop lab reads the precomputed Hivemind book; when a position or clock case is not in it, the
  engine switch scores it and adds it (owner, 2026-09-24: one engine, and it fills the database).
- The FICS archive is shown under each board when the file is on this machine (owner, 2026-09-24).
- `Compare clock scenarios` is dropped: the three `Time` chips replace it.
- No engine settings rows: Hivemind takes half the machine's cores (the Stockfish setting defaults to one,
  far too slow for a network engine), 256 MB and batch 8, the old app's defaults.
- The lab’s table budgets are 1500 root / 200 reply nodes, every legal move; live joint lines use timed passes.
