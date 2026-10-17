# Bughouse

A bughouse analysis board with Hivemind, the two-board engine. The player
moves pieces on one board, or on both boards of a game. They put any piece in
any hand with + and −, and switch the engine on to see its score and lines.

Code: `lib/features/bughouse/` (`BughouseLab` table owner, `LabEngine`, screen,
boards, hands, engine lines and panel), plus `lib/chess/bughouse/` (table, line,
FEN reading, BPGN, crazyhouse PGN, engine-line steps, Hivemind score scale), `lib/engines/hivemind_engine.dart`,
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
  above it and its engine rows under it.
- **Hands** — above and below each board, as lila's crazyhouse pocket: a turn
  dot, the seat letter (two boards only), then five square-sized slots (P N
  B R Q) with counts. A row of + sits over the slots and a row of − under
  them: `One more knight for Black`, `One knight fewer for Black`. Only the
  player on move can drop: click the piece (its legal squares ringed) then a
  square, or drag it.
- **Arrows** — while the engine is on, each board shows its best moves as
  lila's analysis board does: the first in lila's pale blue (15/64 of a
  square wide), the others in pale grey, 12/64 wide when level with it down
  to 2/64, and none once a move is 0.2 behind (half the difference in
  Hivemind's Q). A drop is its piece faint on the square instead. A
  right-drag draws an arrow and a right-click a circle, green, or red with
  Shift, blue with Alt, yellow with Ctrl; a left click or a new position
  takes them away.
- **Panel** — `1 board` | `2 boards`, and `Edit board` at the right of that
  row. Under it, in the same compact segments, who may sit: `A + B may sit`
  | `C + D may sit`, or with one board `White may sit` | `Black may sit`
  (the default is C + D, Black). Hivemind has no case where neither may:
  its one clock input says whether the searched team may sit, and its
  search gives the other team the opposite. The tooltips explain each.
- **Engine bar** — a switch (`Toggle engine (E)`), the score in 18 px mono,
  then `Hivemind · 12,400 nodes` (the size of the search the rows come from,
  both teams' together with two boards), or why the engine stopped, in the
  error colour. While the engine searches, a 2 px bar under it fills towards
  the size the search rests at.
- **Lines** — each board's three best moves for the player on move there,
  one row each: in the panel with one board, under the board (below its
  bottom hand) with two. A row is its score, then the
  move in bold and that board's moves after it, up to eight (`1. d4 d5 2.
  Nf3`); a row whose choice is to wait there starts with a muted `sit`.
  The engine ranks joint actions over both boards, so a team on move on
  both repeats one board's move across its lines; the rows are the three
  moves it visited most on that board (from 16 lines asked), each with its
  most-visited line, best-scoring first. The engine's own choice is not
  pinned on top, so rows swap as the scores move during a live search.
  Each move is its own token, as in the workspace's engine lines.
  Rows are 28 px, clip what does not fit, and keep their place and size
  whether the engine is on or off or a move is hovered; an empty row is
  blank. Scores are A + B's, on Hivemind's scale (`+ is good for A + B:
  White on board 1, Black on board 2. Hivemind's scale, not pawns.`).
- **Problem line** — one fixed line saying why a move, step or paste was
  refused.
- **Moves** — the rest of the panel. With one board, board 1's moves and
  hand edits; with two, board 1's and board 2's lists side by side, each
  under its board's name, the list of the board last used outlined in the
  accent. Each list has `First move`, `Back`, `Forward` and `Last move`
  under it.

## Actions

**Play a move or drop** — on a board, or by clicking an engine row → it joins
that board's line after what is shown, and a capture goes to the partner's
hand. A pawn reaching the last rank waits for the piece it becomes, on either
board, with the workspace board's chooser (queen, knight, rook, bishop down
the file); clicking away plays nothing. Underpromotions keep their piece in
copied and pasted moves and in engine moves; an engine move without a piece is
a queen. With one board the partner board is not shown, so a captured piece
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
**Step a board** — its list, its buttons, or ← → and Home / PgUp, End / PgDn
for the board last used (always board 1 with one board); the mouse wheel over
a board steps that board, down forward and up back. F flips the boards. Only that board moves. A refused step:
`Can't step there: <san> on board 2 would have no piece to drop.`
**Point at a line** — draws its move on its board alone, in the best
move's blue (an arrow, or a faint piece for a drop), until the pointer
leaves. Resting on one of its moves for
80 ms floats a 200 px board under it: the board that move is on, after it,
with the move highlighted and both hands. A new table takes the floated board
away; the search's next report on the same table keeps it.
**Play a line** — clicking a move plays the line up to and including it: with
one board, board 1's moves; with two, every move of both boards before it in
order. All or nothing: `That line no longer fits the position.` Clicking the
row outside its moves plays its move on that board; a `sit` row plays
nothing. Space plays the first row's move on the board last used, as on
lila. The right button
on a row offers `Copy line PGN`: the moves on the boards now followed by the
line, as far as it plays, in the same form as a move's.
**Move menu** — the right button on a move in a board's list: `Copy line PGN`
(the line up to that move in the order played), `Copy FEN` (that board's
crazyhouse FEN just after it), with two boards `Copy dual FEN`, and `Delete
from here` (that move and the board's later moves and hand edits; the other
board keeps its moves). A delete that would take a capture the other board
dropped is refused: `Can't delete: P@d5 on board 2 would have no piece to
drop.` With one board the line PGN is crazyhouse, which Lichess imports:
`[Variant "Crazyhouse"]`, `[SetUp "1"]` and `[FEN …]` with the hands when the
start is not the usual one, then SAN with drops as `N@f3` and `P@e5`. It plays
by crazyhouse rules, so a piece taken stays in the taker's hand there; a drop
those rules would not allow (a piece from a hand edit) starts the PGN again
from the board just before it. With two boards it is the BPGN `Copy moves`
writes.
**Engine switch** (E, or `Toggle engine`) — Hivemind runs only while the switch
is on and the mode is on screen. Each team searched gets one continuous search
on its own engine process; the two processes share the mode's cores. The
score, rows and node count follow the search about four times a second, the
first within about a second of a position, and the search rests at 100,000
nodes until the table changes. One board: the team on move on board 1 must
move there unless the clock choice lets it sit, and the partner board stands as it is (the
desktop Hivemind lacks the website's
`tools/bughouse_web/patches/frozen-board.patch`, so its search may still weigh
partner-board moves). The partner board is given the other team's turn, so
that team can be searched, to 20,000 nodes, for the score's zero; until its
first report the score is the shown team's own. Two boards: each team with a
move is searched, and may sit as the clock choice says. A new position,
board count or clock cuts the searches short. Finished searches are remembered for the
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
moves to paste.`). `Open BPGN…` asks for a `.bpgn`, `.pgn` or `.txt` file
and reads it as a paste, where it is, without keeping it (`Not opened:
<token> in <file> does not play.`, `<file> could not be read.`). The window's
paste commands are refused here with
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
  offset `(q_A+B + q_C+D) / 2` from both teams' latest reports, or none when
  one team was not searched or has not reported yet. The right to sit stays
  in the score: a level opening reads about +2.3 when A + B may sit and
  −2.3 when C + D may. It is not pawns.
- Nothing is saved. Leaving the mode keeps the table for the session; quitting
  the app loses it. No database is read or written.

## Owner decisions

- One board and two boards, both with + and − on every hand; no precomputed
  book, FICS archive, expectimax or matches in the app (owner, 2026-10-16).
- One engine, behind a switch (2026-09-23).
- Who may sit is the only clock question, with one board too, so lines can
  be found with the opponent allowed to sit. Two choices, as Hivemind has
  them, styled like the board count; only the chosen case is searched and
  scored (2026-10-17).
- Two-board lines are per board, under their board, not per team; engine
  arrows and drawn shapes as on lila's analysis board (2026-10-17).
- With two boards the move lists are in the panel, side by side, so the
  boards get the height (2026-10-17).
- No engine settings rows: Hivemind takes half the cores, 256 MB, batch 8
  (2026-09-23).
- The engine behaves like Stockfish elsewhere: switched on, its score, lines
  and node count update as it searches, with no visible passes (2026-10-17).
- No eval bar and no filler empty states (DESIGN.md).
