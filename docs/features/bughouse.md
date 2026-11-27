# Bughouse

A bughouse analysis board with HypeBeast, the bughouse engine. The player
moves pieces on one board, or on both boards of a game. They put any piece in
any hand with + and −, and switch the engine on to see its score and lines.
They open a BPGN file, a FICS archive or an arena match, and play its games
through with the players' names and clocks beside the boards.

Code: `lib/features/bughouse/` (`BughouseLab` table owner, `LabEngine`, screen,
boards, hands, engine lines and panel), plus `lib/chess/bughouse/` (table, line,
FEN reading, BPGN reading and writing, a game's tags and clocks, crazyhouse
PGN, engine-line steps, and `hypebeast.dart`: the engine's lines, coordinator
report, rows and scores read back), `lib/engines/hypebeast_engine.dart`,
`lib/engines/hypebeast_install.dart`, `lib/app/bughouse_view.dart` (`BughouseView`),
the shared board editor `lib/workspace/board/board_editor.dart` and
`lib/app/self_test.dart`. The engine is
[HypeBeast](https://github.com/Zinkelburger/HypeBeast), a Fairy-Stockfish fork
that plays one seat of a bughouse table knowing the other board.

## Screen

`Bughouse` is in the mode menu under `Data & engines`. It is listed only when
the build carries the engine assets. Entering the mode pauses the workspace's
Stockfish (`Paused while Bughouse is open`). The boards are on the left and the
panel on the right: 440–640 px beside board 1 alone, 440–480 px beside both.

- **Boards** — `1 board` (the default) shows board 1 alone, 200–720 px.
  `2 boards` shows both boards side by side, each 200–480 px, sized to the
  window. Board 1 has A (White) and C (Black); board 2 has D (White) and B
  (Black). The teams are A + B and C + D. With two boards, A + B's colour is
  at the bottom of both boards unless flipped, and each board has its name
  above it and its engine rows under it.
- **Hands** — above and below each board, as lila's crazyhouse pocket: a turn
  dot, the seat letter (two boards only), then five square-sized slots (P N
  B R Q) with counts. While the pointer is over a slot, or one of its
  controls has the keyboard's focus, the slot shows a − in its upper left
  corner and a + in its upper right: `One knight fewer for Black`,
  `One more knight for Black`; a − with nothing to take and a + at 16 are
  left out. Only the
  player on move can drop: click the piece (its legal squares ringed) then a
  square, or drag it.
- **Players and clocks** — with a game read from a BPGN, the end of each
  hand's row has who sits there (`larso 2121`, the rating muted, the whole
  name on hover) over that seat's clock in 16 px mono (`1:58`, tenths under
  ten seconds: `0:07.4`), the clock of the player on move in full ink. The
  clock is what the game noted after that seat's last move on the board now,
  or the time the game started with before it has moved, so it follows the
  boards as they are stepped. The two stay within the hand's height; a hand
  under 40 px tall has the name beside the clock, and a clock with too
  little room is drawn smaller, never cut. A line made in the mode has
  neither.
- **Arrows** — while the engine is on, each board shows its best moves as
  lila's analysis board does: the first in lila's pale blue (15/64 of a
  square wide), the others in pale grey, 12/64 wide when level with it down
  to 2/64, and none once a move is 0.2 behind (half the difference in lila's
  winning chances of the two scores, a mate counting as the whole chance)
  or has no score. A drop is a ring on its square in the same colour, with
  the piece inside at 0.8 of a square (60% opaque for the first, 40% for
  the others), as lila draws crazyhouse drops. A
  right-drag draws an arrow and a right-click a circle, green, or red with
  Shift, blue with Alt, yellow with Ctrl; a left click or a new position
  takes them away.
- **Panel** — `1 board` | `2 boards`, and `Edit position…` at the right of that
  row.
- **Engine bar** — a switch (`Turn engine on`), the score in 18 px mono,
  then `HypeBeast · 1,240,000 nodes` (the size of the searches the rows come
  from, both boards' together with two boards), or why the engine stopped,
  in the error colour. The score is A + B's in pawns: with one board, the
  first row's (tooltip `+ is good for White on board 1 (A + B). In pawns.`);
  with two, both boards' first rows added, since a team's winning chances
  follow the plain sum of its two boards' scores, with a forced mate on
  either board shown as the mate (two mates: the quicker), and before both
  boards have reported, the one that has (tooltip `+ is good for A + B:
  White on board 1, Black on board 2. Both boards’ scores added, in
  pawns.`). While the engine searches, a 2 px bar under it fills as the
  search's ten seconds go (it moves without a measure while the engine is
  still starting). The engine is told the game that led to the table
  (`position fen … moves 1e2e4 …`), so it knows a position that came up
  before; a table set up by FEN, or one whose hands were edited on the way,
  is asked about as it stands.
- **Lines** — up to three rows per board for the player on move there: in
  the panel with one board, under the board (below its bottom hand) with
  two. A row is its score, then the move in bold and that board's moves
  after it, up to eight (`1. d4 d5 2. Nf3`). With one board the rows are the
  engine's three best lines of board 1, each whole. With two, while the
  engine searches, a board has one row, its main line; once the search ends,
  the engine's decision comes first (as the main line when it is the main
  line's move), then the other moves its coordinator compared across the
  boards, best first, each a row of that one move with the coordinator's
  score; a move it compared without scoring shows a muted `—`. A decision
  to wait there is a row of its own, a muted `sit` without a score. Each
  move is its own token, as in the workspace's engine lines. Rows are 28 px,
  clip what does not fit, and keep their place and size whether the engine
  is on or off or a move is hovered; an empty row is blank. Each row's score
  is its own board's, A + B's in pawns (`+0.25`, `-1.40`, `#3`, `#-2`),
  converted from the side to move there; the tooltip says whose side `+`
  is.
- **Problem line** — one fixed line saying why a move, step or paste was
  refused.
- **Game row** — only with a game read from a BPGN that has tags: who won
  and how, then the event, round and date (`A + B won · checkmate · Bughouse
  Arena · Round 3`), cut short where the panel ends and whole on hover. When
  the file holds several games the row starts with `‹ [n] of N ›`, the
  viewer's game counter: the arrows step a game, a number typed and Enter
  jumps to it.
- **Moves** — the rest of the panel. With one board, board 1's moves and
  hand edits; with two, board 1's and board 2's lists side by side, each
  under its board's name, the list of the board last used outlined in the
  accent. Each list reads like the workspace's move list: the main line as
  running mono text (`1. e4 e5 2. Nf3`), each variation an indented block
  with a rule on its left right after the move it replaces, starting with
  its number (`2... d6 3. d4`), and the move the board is at tinted in the
  accent. A hand edit is a token of its own in muted ink (`+2n −P`, White's
  pieces in upper case), `Hands edited` on hover. A move from a game read
  from a file names its player on hover; other moves have no hover text.
  Each list has `First move`, `Back`, `Forward` and
  `Last move` under it, which step that board.

## Actions

**Play a move or drop** — on a board, or by clicking an engine row → it
follows the move the board is at. An existing continuation is reused when
it is the same move and replaying it in its recorded order reaches the
same position as playing it now. Otherwise the move starts a variation if
the board already went on from there. A capture goes to the partner's hand.
A pawn reaching the last rank waits for the piece it becomes, on either
board, with the workspace board's chooser (queen, knight, rook, bishop down
the file); clicking away plays nothing. Underpromotions keep their piece in
copied and pasted moves and in engine moves; an engine move without a piece is
a queen. With one board the partner board is not shown, so a captured piece
leaves board 1. Refusals: `That drop is not legal.`, `It is not black's turn
on board 2.`, `That line no longer fits the position.`
**Add or take a hand's piece** — a slot's + or − (pointer over the slot) →
one more or one fewer of that piece,
0 to 16. The edit is a step of that board's line after the move it is at,
as on the website: the moves before it stay, and stepping onto it puts it on,
back off it takes it off. Presses while the board is on an edit nothing
follows yet are one edit, and one that comes back to nothing is gone. Made
where the board already goes on, like a different move, it starts a
variation.
**Edit position…** — opens the shared board editor on board 1 (one board) or the
board last clicked (two boards), without the hands → `Use this position` sets
that board's pieces, side to move and castling, keeps both hands and starts a
new line. A promoted piece left on its square stays promoted, so taking it
still gives a pawn. A board no game can go on from: `That board cannot be played from.`
**Step a board** — its list, its buttons, or the mouse wheel over it, down
forward and up back → that board is at the move, and the other board is
where it was when that move was played, so both hands are as they were and
every drop has its piece. `First move` puts the other board where it was
when this one first moved. Forward and `Last move` follow the main
continuation from where the board is, as in the workspace; a variation is
entered by clicking it. The boards replay in the order their moves were
made. A step is refused only when the capture a drop came from has been
deleted: `Can't step there: <san> on board 2 would have no piece to drop.`
**Step the game** — ← → and Home / PgUp, End / PgDn. With one board they
step board 1. With two they step the game in the order its moves were made:
→ plays the next move of the two boards' lines, the one made first (when it
does not play from the table on screen, the other board's), ← takes off the
move made last, Home puts both boards at their starts and End at the ends of
their lines. The board that moved is the board last used. F flips the
boards.
**Step the file** — the game row's arrows or number, or ↓ and ↑ → the next
or previous game of the opened file, at its first move, with its players. A
game with a move that does not play is shown without its moves, at its own
start (its `SetUpDualFEN`, when it has one), its players kept and the move
named (`Not opened: <token> in <file> does not play.`), so the games after
it can still be reached.
**Point at a line** — draws its move on its board alone, in the best
move's blue (an arrow, or a ringed piece for a drop), until the pointer
leaves. Resting on one of its moves for
80 ms floats a 200 px board under it: the board that move is on, after it,
with the move highlighted and both hands. A new table takes the floated board
away; the search's next report on the same table keeps it.
**Play a line** — clicking a move plays its board's line up to and including
it. All or nothing: `That line no longer fits the position.` Clicking the
row outside its moves plays its move on that board; a `sit` row plays
nothing. Actions ▸ `Play best move` plays the first row's move on the board
last used. The right button
on a row offers `Copy line PGN`: the moves on the boards now followed by the
line, as far as it plays, in the same form as a move's.
**Move menu** — the right button on a move or hand edit in a board's list, as
in the workspace: `Promote variation` (the variation it is in one place up),
`Make main line` (its line the board's main line), both off when it already
is; `Delete from here` (it and everything after it on that board, variations
too; the other board keeps its moves); `Copy line PGN` (the line up to it as
the boards stood when it was played, in the order played), `Copy FEN` (that
board's crazyhouse FEN just after it) and, with two boards, `Copy dual FEN`. A
delete is refused if a surviving partner-board drop needs that capture, even
beyond the cursor or in a variation: `Can't delete: P@d5 on board 2 would
have no piece to drop.` With one board the line PGN is crazyhouse, from the line's start:
`[Variant "Crazyhouse"]`, `[SetUp "1"]` and `[FEN …]` with the hands when the
start is not the usual one, then SAN with drops as `N@f3` and `P@e5`, and each
hand edit a comment where it was made, `{ +P +B }`. Lichess imports it by
crazyhouse rules, where a piece taken stays in the taker's hand and an edit is
only a comment, so its import stops at a drop of a piece from a hand edit.
With two boards it is BPGN moves without a game's tags or clocks.
**Engine switch** (or Actions ▸ `Engine on`) — HypeBeast runs only while the
switch is on and the mode is on screen. One board: one engine process
searches board 1 for its side to move, on that board alone (`Coordination`
off) with three lines; the partner board is passed as the table has it.
Two boards: each board with a legal move gets its own process, searching
it for its side to move with the coordinator on, which first searches the
partner board and then weighs what the moves send across. Each search runs
for ten seconds (`go movetime 10000`), the score, rows and node count
following it as it reports, then rests until the table changes. The
processes share the machine's cores but one, and hold a 128 MB hash table
each between searches. No clocks are sent, so the engine never sits by its
clock rules. A new position, board count or switch cuts the searches short
and drops their answers. Finished searches are remembered for the session
(by table, moves played, board count and board). Leaving the mode quits the
engines.
**Actions menu** — `Engine on` / `Engine off`, `Play best move`, `New game` (start position),
`Flip board(s)`, `Copy dual FEN`, `Paste FEN or dual FEN` (one board's FEN
sets board 1 and starts board 2 afresh), `Copy moves`, `Paste moves`. A FEN
is copied and saved as Lichess writes one, the hand a ninth rank after the
board (`…/RNB1K2R/PNpnb w KQkq - 0 10`, a bare `/` when both hands are
empty), and a dual FEN is two of them joined by `|`. A paste, a set-up box
or a BPGN file takes that or the bracket form (`…/RNB1K2R[PNpnb] w …`);
the engine is sent brackets. Moves
are each board's line without its variations, as BPGN movetext in played order (`1A. e4 1B. d4 1a. e5`), after
`[SetUpDualFEN "…"]` for a set-up start; a hand edit is a comment where it
was made, `{ Hands edited on board 1: +2n }`, and pastes back. A game read
from a BPGN is copied whole: its tags first, each move's clock after it as
FICS writes it (`1A. e4 {119.000}`), then how it ended and its result. Once
the boards are on a line the game did not play, the copy has its tags with
`[Result "*"]`, no ending and `*`. A paste takes any of the forms under
Data, and one game is refused whole (`Not pasted: <token> does not play.`,
`No bughouse moves to paste.`). Tags are read only from a game's header, so
a tag-shaped note in a comment is the comment's. Pasted moves are shown at
their end, to go on from; several games pasted at once are a file, shown at
the first game's start, and refused, the boards kept, when that first game
does not play.
`Open BPGN…` asks for a `.bpgn`, `.pgn` or `.txt` file and reads it as a
paste, where it is, without keeping it (a large file's games are found off
the UI thread, and each game's text is taken only when it is shown), and
shows its first game at its
first move, to play through (`Not opened: <token> in <file> does not
play.`, `<file> could not be read.`). Moves on board 2, pasted or opened,
switch to `2 boards`. The window's
paste commands are refused here with
`Bughouse pastes from Actions: Paste FEN or dual FEN, or Paste moves.`

## Data

- **Engine** — `hypebeast-linux`, `hypebeast-windows.exe` or
  `hypebeast-macos` (about 3.3 MB, a static build of the HypeBeast release
  pinned in `tools/assets.lock.json`) and Fairy-Stockfish's bughouse net
  `bughouse-cd8cceab93fe.nnue` (58 MB; the engine takes a net for the
  variant its file name starts with) from `assets/bughouse/`. They are
  installed into `<support>/bughouse/` and checked against `manifest.json`
  (size, SHA-256) before every launch; a mismatch is rewritten via a `.part`
  file. Hivemind, the engine the folder held before, is removed from it by
  its files' names. Each process is started with `HypeBeast`, `EvalFile`
  (the installed net) and `Hash` 128, then proves its net with a one-node
  search: the engine names the net it evaluates with at a search's start,
  prints `info string ERROR` and exits when the file does not load, and
  falls back to a classical evaluation when it does not take the file for a
  bughouse net; the last two are a start failure (`The bughouse engine did
  not start: its net did not load.`). Each search sets `Threads`, `Seat`
  (`Ablack`: the board and the colour to move there), `Team`, `Coordination`
  and `MultiPV` when they change. Windows explains the loader exits
  `0xC0000135`, `0xC000007B`, `0xC000001D` and `0xC0000005`.
  `--self-test-bughouse=<report.json>` installs, starts and queries the
  engine as the mode does, and exits 0 on success. `tools/windows_self_test.ps1`
  and `.github/workflows/windows-check.yml` (pushes to `windows-check`, Server
  2022 and 2025) run it.
- **Score** — the engine scores in centipawns, or plies to mate, from the
  side to move on the board searched. The mode shows pawns from A + B's
  side: kept for A or B on move, sign changed for C or D. With the
  coordinator, a compared move's score is its `S` (with what it sends the
  partner board), else its `L` (its board alone), from `info string
  hb_coord`. One board's rows are the last block of lines all searched at
  line 1's depth (a line one or more depths behind is from an earlier
  iteration), sorted by score; a stopped search's last block, which the
  unfinished iteration left uneven, gives way to the block before it. The
  bundle check (`tools/test_bughouse_engine.py run`) keeps out a build that
  does not search every line.
- **BPGN** — a file is split into games where a tag follows movetext. Read
  from a game: `WhiteA`, `BlackA`, `WhiteB`, `BlackB` (A, C, D and B) and
  their `…Elo`, `TimeControl` (`120+0` or `120`, the seconds each clock
  starts with), `Result` (`1-0` is A + B's win), `Termination`,
  `SetUpDualFEN`, and the moves in the order played: `1A.` is board 1's
  White, `1a.` its Black, `1B.` and `1b.` board 2's. A move is SAN or
  coordinates (`e7e5`, `f7g8q`, `N@f3`). The comment right after a move is
  the mover's clock: FICS's `{119.000}`, the arena's `{[%clk 0:01:58.1]
  [%eval 3.19] 45.2s}`, or an older arena file's `{1.9s 118.1}`. Scores and
  other comments are passed over; with no `Termination` tag the last
  comment says how the game ended (`LinusO checkmated`). An older arena
  file kept its opening only in an `Opening` tag of engine moves (`1e2e4
  2d2d4`): when the movetext does not play from the start, it is played
  after those, and that tag is dropped, its moves being in the line. The
  other tags, the arena's `Opening` among them, are kept and copied back.
  The arena writes each clock rounded to tenths (`[%clk 0:01:00.0]`).
- Nothing is saved. Leaving the mode keeps the table for the session; quitting
  the app loses it. No database is read or written.
