# Bughouse

A bughouse analysis board with Hivemind, the two-board engine. The player
moves pieces on one board, or on both boards of a game. They put any piece in
any hand with + and −, and switch the engine on to see its score and lines.

Code: `lib/features/bughouse/` (`BughouseLab` table owner, `LabEngine`, screen,
boards and panel), plus `lib/chess/bughouse/` (table, line, FEN reading, BPGN,
Hivemind score scale), `lib/engines/hivemind_engine.dart`,
`lib/engines/hivemind_install.dart`, `lib/app/bughouse_view.dart` (`BughouseView`),
the shared board editor `lib/workspace/board_editor.dart` and
`lib/app/self_test.dart`. Engine internals: [Hivemind](../HIVEMIND.md).

## Screen

`Bughouse` is in the mode menu under `Data & engines`. It is listed only when
the build carries the engine assets. Entering the mode pauses the workspace's
Stockfish (`Paused while Bughouse is open`). The boards are on the left and the
panel (440–480 px) on the right.

- **Boards** — `1 board` (the default) shows board 1 alone, 200–720 px.
  `2 boards` shows both boards side by side, each 200–480 px, sized to the
  window. Board 1 has A (White) and C (Black); board 2 has D (White) and B
  (Black). The teams are A + B and C + D. With two boards, A + B's colour is
  at the bottom of both boards unless flipped, and each board has its name
  above it and its own move list and step buttons under it.
- **Hands** — above and below each board, as lila's crazyhouse pocket: a turn
  dot, the seat letter (two boards only), then five square-sized slots (P N
  B R Q) with counts. A row of + sits over the slots and a row of − under
  them: `One more knight for Black`, `One knight fewer for Black`. Only the
  player on move can drop: click the piece (its legal squares ringed) then a
  square, or drag it.
- **Panel** — `1 board` | `2 boards`, and `Edit board` at the right of that
  row. With two boards, `Time` follows: `A + B may sit` / `Even` / `C + D may
  sit`. The tooltips explain each.
- **Engine bar** — a switch (`Toggle engine (E)`), the score in 18 px mono,
  then `Hivemind · 12,400 nodes` (the size of the search the rows come from,
  both teams' together with two boards), or why the engine stopped, in the
  error colour. While the engine searches, a 2 px bar under it fills towards
  the size the search rests at.
- **Lines** — one board: three rows, each with a score and board 1's moves
  (`1. e4 e5 2. Nf3`). Two boards: an `A + B` and a `C + D` header, each over
  three rows of seat-lettered joint actions (`A e4 B sits · C e5 D d4`). Rows
  are 28 px and keep their place whether the engine is on or off; an empty row
  is blank. Scores are A + B's, White's on board 1, on Hivemind's scale (`+ is
  good for White on board 1 (A + B). Hivemind's scale, not pawns.`).
- **Problem line** — one fixed line saying why a move, step or paste was
  refused.
- **Moves** — with one board, board 1's moves and hand edits fill the rest of the panel, with
  `First move`, `Back`, `Forward` and `Last move` under them.

## Actions

**Play a move or drop** — on a board, or by clicking an engine row → it joins
that board's line after what is shown, and a capture goes to the partner's
hand. With one board the partner board is not shown, so a captured piece
leaves board 1. Refusals: `That drop is not legal.`, `It is not black's turn
on board 2.`, `That line no longer fits the position.`
**Add or take a hand's piece** — + or − → one more or one fewer of that piece,
0 to 16. The edit is noted after that board's current move, as on the
website: the moves before it stay, and its list shows the net change after
the move in muted ink (`e4 +2n −P`, White's pieces in upper case), or on a
`Start` row before the first move. Stepping back past the move takes the
edit off; stepping forward puts it back. Repeated presses at one place are
one edit. Like a different move, an edit made after stepping back replaces
that board's later moves.
**Edit board** — opens the shared board editor on board 1 (one board) or the
board last clicked (two boards), without the hands → `Use this position` sets
that board's pieces, side to move and castling, keeps both hands and starts a
new line. A board no game can go on from: `That board cannot be played from.`
**Step a board** — its list, its buttons, or ← → Home End for the board last
used (always board 1 with one board). Only that board moves. A refused step:
`Can't step there: <san> on board 2 would have no piece to drop.`
**Point at a line** — draws its first move on the board (an arrow, or a faint
piece for a drop) until the pointer leaves.
**Engine switch** (E, or `Toggle engine`) — Hivemind runs only while the switch
is on and the mode is on screen. Each team searched gets one continuous search
on its own engine process; the two processes share the mode's cores. The
score, rows and node count follow the search about four times a second, the
first within about a second of a position, and the search rests at 100,000
nodes until the table changes. One board: the team on move on board 1 must
move there, nobody may sit, and the partner board stands as it is (the
desktop Hivemind lacks the website's
`tools/bughouse_web/patches/frozen-board.patch`, so its search may still weigh
partner-board moves). The partner board is given the other team's turn, so
that team can be searched, to 20,000 nodes, for the score's zero; until its
first report the level table's zero stands in. Two boards: each team with a
move is searched, and may sit as `Time` says. A new position, board count or
clock cuts the searches short. Finished searches are remembered for the
session. Leaving the mode quits the engines. An engine build that cannot
report while it searches is asked in passes of 800, 4,000 and 20,000 nodes on
one process, the rows changing as each pass ends.
**Actions menu** — `Toggle engine`, `New game` (start position, clock kept),
`Flip board(s)`, `Copy dual FEN`, `Paste FEN or dual FEN` (one board's FEN
sets board 1 and starts board 2 afresh), `Copy moves`, `Paste moves`. Moves
are BPGN movetext in played order (`1A. e4 1B. d4 1a. e5`), after
`[SetUpDualFEN "…"]` for a set-up start; a hand edit is a comment where it
was made, `{ Hands edited on board 1: +2n }`, and pastes back. A paste takes that or a FICS game,
and is refused whole (`Not pasted: <token> does not play.`, `No bughouse
moves to paste.`). The window's paste commands are refused here with
`Bughouse pastes from Actions: Paste FEN or dual FEN, or Paste moves.`

## Data

- **Engine** — `hivemind` (~3.7 MB, release `engine-v0.2.0` of the
  Zinkelburger/hivemind fork; Windows builds the same revision itself), ONNX
  Runtime (~28 MB) and `hivemind.onnx` (~54 MB) from `assets/bughouse/`. They are installed into
  `<support>/bughouse/` and checked against `manifest.json` (size, SHA-256)
  before every launch; a mismatch is rewritten via a `.part` file. Windows:
  the VC++ DLLs from `data/bughouse-runtime/` are copied the same way, the
  engine's PATH is its folder plus System32, and exits `0xC0000135`,
  `0xC000007B` and `0xC000001D` are explained. Options: half the machine's
  cores, `Hash` 256, `BatchSize` 8. `--self-test-bughouse=<report.json>`
  installs, starts and queries the engine as the mode does, and exits 0 on
  success. `tools/windows_self_test.ps1` and
  `.github/workflows/windows-check.yml` (pushes to `windows-check`, Server
  2022 and 2025) run it.
- **Score** — Hivemind prints `180·tan(1.56·Q)`. The mode re-centres in Q with
  offset `(q_A+B + q_C+D) / 2` from both teams' latest reports, or the
  level-table offset (±0.5814 per team's sit bit) when one team was not
  searched or has not reported yet. 0.00 is
  level. It is not pawns.
- Nothing is saved. Leaving the mode keeps the table for the session; quitting
  the app loses it. No database is read or written.

## Owner decisions

- One board and two boards, both with + and − on every hand; no precomputed
  book, FICS archive, expectimax or matches in the app (owner, 2026-10-16).
- One engine, behind a switch (2026-09-23).
- The three `Time` chips are the only clock question, and only with two boards
  (2026-09-23).
- No engine settings rows: Hivemind takes half the cores, 256 MB, batch 8
  (2026-09-23).
- The engine behaves like Stockfish elsewhere: switched on, its score, lines
  and node count update as it searches, with no visible passes (2026-10-17).
- No eval bar and no filler empty states (DESIGN.md).
