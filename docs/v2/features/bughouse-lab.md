# Bughouse lab

Status: draft from the old app
Old code (oracle only): `lib/features/bughouse/`, `lib/widgets/board_editor/`, `tools/bughouse_db/`
Plan step: 12

## Purpose
A bughouse player sets a two-board position up — from the start, a typed line or a dual FEN — and asks
a neural-network engine what the *team* should do, with sitting and the clock as first-class inputs.
They leave with a ranked answer for both boards, what the FICS archive played there, and optionally a
self-play score for the line.

## Screen
Reached from the mode menu, group `Lab`, as `Bughouse lab`; the whole mode is removed from the menu
when the build carries no engine. No screenshot.

- **Top bar** — breadcrumb, a `Board` overflow menu (`Flip board A`, `Flip board B`), the mode
  switcher, a settings gear repeating the engine settings.
- **Board columns** — `Board 1` and `Board 2` side by side, each stacking header, far seat, far
  reserve, the board (240–400px, sized from the leftover height so the pair never resizes mid-game),
  near reserve, near seat, and a fixed 68px movetext column numbered as *that* board counts, drops
  written `P@f7`, the cursor's ply lit, click to jump, empty `No moves on this board yet.` On a
  narrow window the side panel stacks below instead of beside.
- **Board header** — the board's name, the last move played *on that board* (`12. Nf3`, blank before
  the first), a copy-moves button (disabled while empty) and `Draw board 1 the other way up`.
- **Seat rows** — four people, not two colours: a letter badge `A`/`B`/`C`/`D` on a white or black
  chip (ours outlined), the role in words (`You`, `Opponent`, `Partner`, `Partner's opponent`), a
  fixed-width to-move marker, and an editable clock (default 3:00, `m:ss` or bare seconds, committed
  on blur or Enter). Between each seat and the board its reserve: five slots (pawn to queen, never a
  king) always drawn, empty ones faint so the tray never reflows, every piece counted.
- **Line controls** (under both boards) — start / back / `cursor / length` / forward / end, `Take the
  last move back`, a copy menu (`Both boards' moves`, `Dual FEN`), `New game`, and the FICS book
  toggle, disabled with `No FICS bughouse database on this machine`.
- **Side panel** — one card in three modes, with tabs `Engine`, `Board`, `Engine settings`; outside
  analysis an eyebrow reads `EDIT POSITION` or `ENGINE TOURNAMENT` and the corner button says `Done`.
- **Score header** (pinned, never scrolls) — pause/resume, the score at 26px, `You + Partner`, icons
  for `Edit position` and `Engine tournament`, and under it `depth 14 · 120000 nodes · 8s`, or
  `Loading the network…` / `Thinking…` / `Paused` / `Comparing clock scenarios…`, plus `· read off
  their search` when our team had no move and the number came from theirs.
- **Engine tab** — per board, `Board 1   White to move` and one row slot per requested line (empty
  slots keep their height): a 54px score column, then that board's part of the joint line as numbered
  SAN, `sit` for a deliberate pass, blank where the seat had nothing to decide. Superseded rows read
  `no longer fits this position`; before the first result, `Thinking…` or `Analysis paused`. A
  comparison puts its own block above them (`Comparing… 2 of 3 ready`, `Comparison complete`,
  `Comparison stopped · 1 of 3 ready`; a row per scenario — `Ahead (may sit)`, `Level or behind`,
  `Forced to move on 1` — with score and seat-labelled moves) and heads the live lines `CURRENT
  CLOCK SETTINGS · PAUSED`.
- **Board tab** — `You play on Board 1` (`White on 1` / `Black on 1`), `Your team's clock advantage`
  (`Ahead` / `Level` / `Behind`), `Use the board clocks` (the segments then go read-only; both
  diagonal pairs must agree by more than 5 seconds, and clocks do not run in this model),
  `Require a move` (`Allow sitting` / `On 1` / `On 2`), and `Compare clock scenarios`.
- **Engine settings tab** — number steppers for `CPU cores` (Linux only, default 2, capped by the
  parent CPU set; elsewhere `CPU cores: managed by this engine build`), `Lines` (1–10, default 3),
  `Memory` (16–65536 MB, default 256), `Time per pass` (1–3600 s, default 30) and `Batch size`
  (1–1024, default 8), with the note that larger batches may be faster but not better.
- **Banner** — a failure or a notice above the tabs; a failure carries `Copy full report`, `Show
  details` over a bounded report, and on Windows `Download the Microsoft runtime`.
- **FICS archive block** — under the lines when the book is open: `FICS archive`, `{games} games ·
  {years}` (read from the book's own metadata), a `Board 1` / `Board 2` filter, then up to 12 recorded continuations with a W/D/L bar
  always read as *your team* and an average-rating tooltip. Empty it says `No archived game reached
  this position.`, `Past the archive, which is indexed to {plies} plies.`, or `No continuations meet the
  archive minimum of {n} games, or this is the end of the indexed line.`
- **Edit position panel** — `Place pieces` with the shared spare-piece palette and its instruction
  paragraph, then per board `To move`, four castling chips (`K Q k q`), `Start position`, `Clear`;
  then `Dual FEN` with `<Board 1 FEN>|<Board 2 FEN>`, `Load`, `Copy current`, `Paste`.
- **Engine tournament panel** — `New tournament` or `Playing game 4 of 10` with `Stop`; a `HISTORY`
  list (four rows before scrolling, newest first, each with its score); then the run:
  `WHITE ON BOARD 1 SCORED` with the score, percentage, `6W 2D 2L`, a 95% sampling range, excluded
  unfinished games and draws by move limit or mutual sitting; the opening label with `Show`; a
  progress bar; `Follow the game being played`; the games table headed `A + C (White on 1)` / `B + D
  (Black on 1)`; a shut `Crosstable` and `Settings`; `Delete this tournament`. Empty: `No tournaments
  yet` — `Set a position up on the boards, then play it out.`

## Actions
**Play a move or a drop** — drag on either board, or click a reserve piece then a square (its legal
squares light up) → the ply joins the whole-table line, the other board's reserve is credited and
analysis restarts → `Nf3 is not legal here.`, `That drop is not legal.`, `It is not white's turn on
board 2.`
**Walk the line** — arrows, Home/End, a movetext chip, undo; `New game` keeps the team, stance and
clocks and clears both boards.
**Edit a position** — the pencil or the corner button → the boards become the shared lichess-style
editor: drag a piece, paint with a brush held down, right-click to clear or swap the brush's colour;
reserve slots take a click to add and a right-click to remove; turn, castling, `Start position` and
`Clear` sit beside them; `Load` replaces both boards from a pasted dual FEN and resets the line,
`Position loaded.` → `That leaves an impossible position.`, `There is no rook on the square that
right needs.`, `That is not a valid dual FEN.`
**Analyse** — starts when the pane appears, stops when the mode is left (a running tournament keeps
the process alive), pause/resume from the header. Both teams are searched on every pass, because a
two-board position has no single side to move; passes start at 2 s and double up to `Time per pass`,
carrying nothing between them → `Analysis failed: …` with the diagnostic attached.
**Read the score** — the number is **not pawns**: it is Hivemind's own scale (`180·tan(1.56·Q)`)
re-centred. The `TimeAdvantage` bit alone is worth about ±0.58 Q — raw, a level position reads about
−2.3 when neither team may sit — so the offset is measured from this position's two searches, and the
tooltip says whether zero was measured here, carried from the last position, or assumed.
**Hover a line** — a row previews its first ply on both boards and reserves, a move token previews
through that move, leaving a token falls back to the row and leaving the row restores the live
position. User moves are blocked while a preview is up and nothing is written to the line.
**Play a continuation** — click a row or a move token → the joint sequence is played through that
point, including the other board's halves → `That line no longer fits the position.`
**Set the table rules** — team, clock stance, `Use the board clocks`, `Require a move`; each restarts
the search and throws away the measured zero.
**Compare clock scenarios** — Board tab → three 6 s searches run in turn, results appear as they land,
live analysis pauses meanwhile and resumes after → `Comparison failed: …`
**Browse the FICS archive** — the book icon → the archive opens in the Engine tab; a row hovers a
preview and clicks to play the move. The key is the *pair* of positions, so every interleaving that
reaches the same place is merged.
**Run a tournament** — the trophy icon, then `New tournament`: a name defaulted to the line; a start
position from `The boards` / `A line` (SAN, `2:` prefixes board 2, board 1 played through first) /
`A dual FEN`; `Games` (1–1000, default 10); `A + C thinks` and `B + D thinks` in nodes a move
(50–1,000,000, default 800 — nodes, so a run replays); Advanced holds variety (8 sampled plies from
the top 3 within 5% of the best), `Swap seats every other game`, a whole-run clock stance, ply limit
(240, filed as a draw), memory and batch → `Play 10 games` → `That is not a position yet — check the
moves or the FEN.`, `Could not create the match directory: …`
**Read a run** — click a history row; `Show` puts the opening on the boards, a games row replays that
game there, `Follow the game being played` returns to the live one → `Could not delete the match: …`
**Keyboard** — ← / → a ply, Home / End the ends of the line; any text field wins the keys.

## Data
- **Engine bundle** — `hivemind` (~1.9 MB), the ONNX Runtime library (~28 MB) and `hivemind.onnx`
  (~54 MB) are extracted gzipped from `assets/bughouse/` on first use into the app's support
  directory, then verified against the shipped `manifest.json` (size and SHA-256) before every
  launch; mismatched files are removed and rewritten. On Windows the build's x64 VC++ DLLs are kept
  privately under `data/bughouse-runtime/` and checked the same way; only engine-local files are ever
  repaired. Failures name the exit code and NTSTATUS. All of it is MIT (Hivemind, aminwoo).
- **Engine settings** — five `bughouse.engine.*` preference keys; a broken store costs the knobs.
- **FICS archive** — read-only `bughouse_book.db` (SQLite, ~177 MB from a 2 GB corpus, 21 years of
  bughouse-db.org BPGN), looked for under `$BUGHOUSE_DB_HOME`, then
  `~/.local/share/chess-prep/bughouse-db/`, then the app support directory; built by
  `tools/bughouse_db` and never written by the app. Keyed by an FNV-1a hash of the canonical dual FEN
  (pocket letters in `KQRBNP` order — one byte of disagreement is a total miss). Results are
  team-relative and `unknown` is real: about one archived game in nine ends `*`.
- **Tournaments** — one directory per run under `Documents/bughouse_matches/<id>/` holding
  `match.json` (config and every game) and `games.bpgn` in the form `tools/bughouse_db` can index;
  deleting quarantines it under `.trash`.
- **Precomputed Hivemind book** — `~/.local/share/chess-prep/bughouse-db/hivemind_book.db`, beside
  the FICS book on the same key: every legal move on both boards scored for the four clock cases with
  a principal variation, to ply 10. Published to **BughouseDB** (`/bughousedb` on the website), and
  **the desktop lab does not read it**.

## Keep / Change / Drop
Keep — Top bar
Keep — Board columns
Keep — Board header
Keep — Seat rows
Keep — Line controls
Keep — Side panel
Keep — Score header
Keep — Engine tab
Keep — Board tab
Keep — Engine settings tab
Keep — Banner
Keep — FICS archive block
Keep — Edit position panel
Keep — Engine tournament panel
Keep — Play a move or a drop
Keep — Walk the line
Keep — Edit a position
Keep — Analyse
Keep — Read the score
Keep — Hover a line
Keep — Play a continuation
Keep — Set the table rules
Keep — Compare clock scenarios
Keep — Browse the FICS archive
Keep — Run a tournament
Keep — Read a run
Keep — Keyboard

Quirks to rule on: the printed score is Hivemind's re-centred scale, not pawns, and its zero can be
measured, carried or assumed; `Level` and `Behind` run the identical search because the engine's clock
model is one bit; the lab saves nothing — leaving the mode or `New game` loses the line, and only
tournament games reach disk; a typed opening plays board 1 through before board 2, so a capture in it
can produce the wrong reserves; the mode vanishes from the menu when the engine was not fetched.

## Questions for the owner
- Should the lab save and reopen a two-board line, or stay a scratchpad?
- Does the desktop lab read the precomputed Hivemind book, or does that stay on the website?
- Do bughouse matches belong in the Engine tournament mode instead of a panel inside the lab?
- Is `Compare clock scenarios` worth keeping, when two of its three cases search identically?
