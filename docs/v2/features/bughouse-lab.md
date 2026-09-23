# Bughouse lab

Status: built 2026-09-23 from the web pages (decisions below, not yet seen by the owner)
Old code (oracle only): `lib/features/bughouse/`, `tools/bughouse_db/`, `tools/mcp/bughouse/`
Web pages it follows: `python/twic-position-finder/frontend/src/pages/bughouse.astro`, `bughousedb.astro`
Plan step: 12

## Purpose
A bughouse player sets a two-board position up — from the start, by playing, or from a FEN per board —
and sees every legal move on each board scored for the clock situation they choose: from the precomputed
Hivemind book when the position is in it, from a live Hivemind search when it is not. They can ask the
engine what their team should play as a joint action over both boards, and see what the FICS archive played.

## Screen
Reached from the mode menu as `Bughouse lab`; the entry is left out when the build carries no engine.
One screen, no scrolling at an ordinary window size, laid out as the BughouseDB page: the two boards on
the left, the question and the tables on the right.

- **Boards** — board 1 has A (White) and C (Black), board 2 D (White) and B (Black); teams A + B and C + D.
  Our team's colour is at the bottom of board 1 until `Flip boards`. Each board is as large as the window
  allows (200–480 px), the last move marked, a move played by click or drag.
- **Seat rows** — above and below each board: a plain turn dot beside the player on move, `Player A`
  in grey (in the text colour when on move), then that player's reserve, each piece once with its count.
  A reserve piece of the player on move is dragged onto the board, or clicked and then its square clicked;
  while it is picked up the squares it may drop on are ringed.
- **Move list** — under each board its own moves, numbered as that board counts them (`1. e4 d5`), the
  current one marked, the ones stepped back past faint; click one to go there. Four step buttons under it.
- **Setup boxes** — per board a FEN box and one reserve box per player (`A`, `C`; `D`, `B`), filled from
  the table as it is played; `Set position` under both boards and a live `Pieces outstanding: …` line
  (`Too many: …` for extras). A dual FEN pasted into either FEN box fills both boards.
- **Chips** — `Our team` (A + B / C + D), `Must move on` (Either / Board 1 / Board 2), `Time` (`A + B may
  sit` / `Even` / `C + D may sit`, Even first, each with its one-line tooltip) and `Search` (3 s / 10 s / 30 s).
- **Buttons** — `Analyze` (`Stop` while it runs), `FICS archive` when this machine has it, `Flip boards`,
  `New game`.
- **Status line** — one line, always there: `From the Hivemind book.`, `Not in the book · searching 3 of
  10…`, `Not in the book · Hivemind scored the likeliest moves.`, `Hivemind is searching for A + B…`,
  `Comparing C + D…`, or what was refused or failed, in the error colour only then.
- **Analyze result** — after Analyze: `A + B: +0.78` (or `Mate for A + B`), then up to three rows `Best`,
  `2`, `3`, each the seat-lettered half on each board where our team is on move (`A dxe5`, `B sits`) and its
  score. The headline's tooltip says where zero came from.
- **Move tables** — one per board side by side, a plain rule between them: header `Move: Player D`, then
  every legal move on that board, drops included, with its score for the chosen `Time`, read from the
  mover's side, best first and bold; unscored moves `—` below by SAN. The score's tooltip is the line after
  the move. The `Score` header's tooltip says it is Hivemind's scale, not pawns.
- **FICS archive** — under the tables while open: `FICS archive · {games} games here · {years}` and up to
  12 continuations, most played first: seat and SAN (`D exd5`), games, and a won / drawn / lost bar for
  our team (average rating and unfinished games in the tooltip). Empty: `No archived game reached this
  position.`, `Past the archive, which is indexed to {plies} plies.`, or `No continuations meet the archive
  minimum of {n} games, or this is the end of the indexed line.`
- **Tables | Matches** — a switch at the top of the right-hand side; Matches puts the lab's matches where
  the chips and tables were.
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
**Read the scores** — the book's when the position is in it, at once for every clock case; otherwise each
team with a move is searched (400 nodes) for the zero and to rank its moves, then each board's four
likeliest moves are played and the answering team searched (200 nodes), as the book builder and
BughouseDB's `Analyze locally` do. Searches are remembered for the session. → `Analysis failed: …`, or the
reason the engine would not start, which stops the tables asking until `Analyze` is pressed.
**Read the score** — Hivemind's own scale (`180·tan(1.56·Q)`), re-centred: each team's search of the
position gives the offset, `(q_A+B + q_C+D) / 2`, taken off in Q; when a team has no move the level-table
offset stands in. 0.00 is level. The book stores the same scale.
**Analyze** — our team searched for the `Search` time with `Must move on` and our clock bit, then the other
team for the zero → the result above the tables; `Stop` keeps what was found against the assumed zero; a
new position, clock or question throws the answer away → `{team} has no move here.`
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
create the match directory: …`, `Could not save the match: …`, or the engine's reason.
**Read a run** — click a history row; `Show` puts the opening on the boards, a game row puts that game on
them at its end, `Follow the game being played` makes the boards follow the live game while the tables
rest; `Stop` drops the game in flight so `Resume` plays it again (as does a last game the engine failed
in; `Resume` reads the match from disk, so a game the old app added since is kept); `Delete` asks, then
moves the match to
`.trash` → `Could not delete the match: …`
**New game / Flip boards** — the start on both boards, the chips kept / the other colour at the bottom.
**Actions menu** — Analyze, New game, Flip boards, Copy dual FEN, Paste dual FEN.

## Data
- **Engine** — `hivemind` (~3.7 MB on Linux), the ONNX Runtime library (~28 MB) and `hivemind.onnx` (~54 MB)
  from `assets/bughouse/`, installed into `<support>/bughouse/` and checked against `manifest.json` (size
  and SHA-256) before every launch; a mismatch is written again from the asset under a temporary name. On
  Windows the build's VC++ DLLs under `data/bughouse-runtime/` are copied beside it the same way. Hivemind
  runs on half of the machine's cores, 256 MB hash, batch 8. MIT (aminwoo).
- **Hivemind book** — read-only `hivemind_book.db` (`tools/bughouse_db/hivemind_book.py`), looked for under
  `$BUGHOUSE_DB_HOME` alone when set, else `~/.local/share/chess-prep/bughouse-db/`, then the support folder.
  Keyed by FNV-1a of each board's four FEN fields with the reserve in `KQRBNP` order, joined by ` | `.
  Scores are A + B's; a book in the old seat lettering (board 1 Black `B`) is read with `B` and `C` swapped.
- **FICS archive** — read-only `bughouse_book.db` beside it, same key; results team-relative.
- **Matches** — one folder per match under `Documents/bughouse_matches/<id>/`: `match.json` (version 1, the
  old app's keys: config with `participants`, `timeStance` ahead/level/behind, `variety`, `seed`; every game
  with its board-digit UCI moves `1e2e4`, `2P@f7`) and `games.bpgn` (four seat tags, `SetUpDualFEN` for a
  set-up start, movetext `1A. e4 1B. d4 1a. e5` in the order played). Both apps list and read the same
  folders; a run either app left `running` reads as stopped. Deleting moves the folder to `.trash`.
- **Nothing else is written.** The lab is a scratchpad: leaving the mode keeps the table for the session,
  quitting loses it.

## Keep / Change / Drop
Keep — Boards
Keep — Seat rows (Change: plain dot and `Player A`, reserve only as held pieces, from the web page)
Keep — Move list (Change: per board, each board steps on its own, from the web page)
Change — Setup boxes replace the Edit position panel (FEN and reserve per board, pieces outstanding)
Change — Chips replace the Board tab (Our team, Must move on, Time, Search)
Change — Move tables replace the Engine tab's lines (every legal move scored, book or live)
Keep — Analyze (Change: one search for the chosen time, not continuous passes)
Keep — Read the score (measured, or assumed when a team has no move; no carried zero)
Keep — FICS archive (a toggle under the tables)
Keep — Point at a row, Play a move or a drop, Step a board, Set a position
Drop — Score header, Engine settings tab, editable clocks, Use the board clocks, Compare clock scenarios
Keep — Engine tournament panel, as Matches behind the Tables | Matches switch (Change: no crosstable or
settings block; `A line` start dropped — play it on the boards; stop drops the game in flight; Resume added)
Keep — Run a match, Read a run

## Decisions (2026-09-23, made without the owner)
- The lab stays a scratchpad; nothing is saved but match games.
- Matches stay inside the lab, on a Hivemind of their own so the tables keep theirs; same folders and
  format as the old app. `Stop` drops the game in flight rather than keeping it unfinished, so `Resume`
  (new) replays it; seeds are per game so a resumed match samples as it would have.
- The desktop lab reads the precomputed Hivemind book, and searches live when the position or clock case is
  not in it. It never writes to the book.
- The FICS archive stays, shut by default, when the file is on this machine.
- `Compare clock scenarios` is dropped: the three `Time` chips replace it.
- No engine settings rows: Hivemind takes half the machine's cores (the Stockfish setting defaults to one,
  far too slow for a network engine), 256 MB and batch 8, the old app's defaults.
- The lab's own search depths (400 / 200 nodes, four moves a board) are fixed.
