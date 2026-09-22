# The workspace

Status: draft from the old app
Old code (oracle only): `lib/widgets/chess_board_widget.dart`, `lib/widgets/board/`,
`lib/widgets/board_editor/`, `lib/widgets/interactive_pgn_editor.dart`, `lib/widgets/pgn/`,
`lib/widgets/engine/`, `lib/widgets/opening_explorer/`, `lib/features/documents/`,
`lib/utils/app_shortcuts.dart`
Plan step: 0, 1, 6

No screenshot: another agent held the app driver during this pass.

## Purpose
The board, move list, engine and explorer every mode borrows. Whoever is reading a game, building
a repertoire, studying or drilling works here, and leaves with a position on the board and, where
the mode allows it, a move, comment or annotation written into the document.

## Screen
Reached from every mode with a board: Builder, PGN Viewer, Study, Trainer, Tactics, Player analysis,
Planner. Wide: board centre, move list and comment above the Engine / Database docks right; under
960px those docks become tabs. v2 already has board, move list, engine pane (200 ms) and eval bar.

- **Board** — one bundled SVG piece set, 2px permanent frame, pieces never animate so a pane resize
  cannot slide them. Coordinates are a Display preference (none / inside (default) / outside / every
  square); outside takes a `(board*0.045).clamp(14,22)` margin, and squares under 24px go bare.
- **Square feedback** — one tint per square, never a border, never a layout change, never over a
  piece. Precedence: selected > explicit hint or hover-from-a-list (blue) > legal destination > last
  move from/to; destinations show only when "Show legal moves" is on (default **off**). No check
  highlight, no hover highlight, no premove.
- **Arrows and circles** — right-drag; same square a circle, else an arrow. Green, Shift red, Alt
  blue, Ctrl yellow; the engine's threat arrow is red.
- **Eval bar** — none in the old app; the only score is the engine gutter. (v2's is 12px left of the
  board, filled from White's edge by expected score `1/(1+e^(-0.00368208·cp))`, flips with it.)
- **Move list** — mono SAN, mainline and variations styled alike, depth shown by indent clamped
  at 3 levels. Runs break every 24 plies, at annotated moves and at branch points. Comments are
  prose inline in the flow, never a side pane; `[%…]` metrics get their own row. The reader caps the
  column at 900px and folds branches deeper than 2; the editor never folds. NAG glyphs follow the SAN
  in bold (`!!` `!` green, `!?` violet, `?!` blue, `?` amber, `??` red); positional ones are muted.
- **Comment panel** — below the moves, always editing the move under the cursor; "Comment", 2–4
  lines, a trash button and six NAG glyphs. At the start it edits the chapter introduction.
- **Engine dock** — a 32px row: on/off switch, status (`Engine`, `Engine busy`,
  `Depth {d} • {n} nodes`, `{n} lines • depth {d}`), a "Show threat" crosshair, a gear. Below it
  exactly MultiPV slots, each a 54px mono eval gutter plus one PV clipped to a row, a chevron
  expanding it to a six-row viewport, and empty slots keeping their height. Defaults: **cores 1**
  (max = logical cores), **memory 128 MB** (16–8192, step 16), **depth 15** (1–99), **lines 3**
  (1–10); evals are White-relative, one decimal (`+0.35`), mate `#5` / `-#5`.
  (v2 has this bar: the 32px switch row with `Depth {d} · {engine}`, 54px gutters, hover floats a
  200px board under the move, a click plays the line up to it, the chevron opens six rows; no
  threat, gear, nodes or settings yet. The old app's large headline score was tried and dropped.)
- **Tab strip and Replies** (v2, 2026-09-21; browser tabs 2026-09-22) — under the engine bar,
  `Moves` | `Replies`, one underlined, the old viewer's closeable side-panel tabs with fixed
  identities: `Moves` is pinned, the others carry an `×` when up or under the pointer, a middle
  click closes, a drag puts a tab in front of another, Ctrl+Tab / Ctrl+Shift+Tab walk them and
  Ctrl+W closes the one that is up. A closed tab comes back from Actions ▸ `Show Replies`; the
  strip is left out while only one tab is open. Which tabs are open is window state, kept across
  modes and lost with the window. Both start open, `Moves` up. `Next gap` sits at the strip's
  right edge on the Replies tab. Replies is the Maia-3 table described in `repertoires.md`: share
  gutter, numbered move, tick or `gap`, a hover board of the position after the move, a click
  plays it. A new tab is one `PaneTab` in `workspace/workspace_tabs.dart` and one body in the card.
- **Explorer (Database dock)** — sources: Engine evals, ChessDB, Repertoire, Opening explorer,
  Local PGN. Live explorer: Lichess, Masters, TWIC (only with a local master database), behind a
  collapsed filter summary; Lichess has speed and rating chips (defaults blitz/rapid/classical,
  2000/2200/2500), TWIC a "Classical OTB only" chip. Columns: **Move** (checked when already in the
  repertoire) · **Games** (`1.2k`/`1.2M` plus share, `<1%` under 0.5%) · **White / Draw / Black**
  bar, closed by a `Σ` totals row — no rating, performance or eval column and no sorting. Below it,
  games here (4+4 Lichess, 15 Masters, 12 TWIC).
- **Board editor** — dialog (960×720) or embedded panel. Spare strips above and below the board
  swap with the flip, each `[pointer] K Q R B N P [bin]`; then side to move, Start position, Clear
  board, Flip board, an advanced section (four castling checkboxes, enabled only with king and rook
  at home; an en-passant picker only when a candidate exists) and a FEN field with copy, paste,
  Apply, Discard. No move-number or halfmove field, and nothing is legality-checked as you work.

### Keyboard

| Key | Does |
|---|---|
| ← / → | Back / forward one move (auto-repeats) |
| Home / End | Start / end of the line |
| ↑ / ↓ | Previous / next item in front of you (game, chapter, puzzle, finding) |
| Enter | Focus the current variation; start solitaire on the setup strip |
| Esc | Leave the innermost thing first; in a text field it only blurs |
| Space | Play/pause replay; show/hide solution in a trainer |
| F / E | Flip the board / toggle the engine |
| F11 | Fullscreen |
| Ctrl+V, Ctrl+Shift+V | Paste PGN, paste FEN |
| Ctrl+Z | Undo the last repertoire add |
| Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+W | Next / previous tab of the reading card; close the tab that is up (v2) |
| 1–4 | Rate Again / Hard / Good / Easy (trainer only) |

Nothing fires while a text field has focus, and a screen with a live move box swallows every bare
chess character (a–h, K Q R N O x, 0–8, `-`, `=`), so `F`, `E` and `1`–`4` are dead there.

## Actions
**Move a piece** — click-click or drag (3px) → played; an illegal drop snaps back with no message.
**Promote** — a scrim offers queen, knight, rook, bishop down the promotion file → completes the
move → clicking the scrim cancels; no key does.
**Play a move** — an existing move only moves the cursor; a new one at a branch point is appended
as the *last* variation, silently, and stays scratch in the reader unless the mode is editing.
**Promote a variation** — "Promote Variation" (one level) or "Make Main Line" → rewrites the
document, re-anchoring the cursor by move sequence → dropped silently if the tree changed meanwhile.
**Delete from a move** — "Delete from Here" → confirms "Delete {n} moves and {m} comments?", then
removes the subtree and its annotations.
**Edit a comment** — "Add/Edit Comment" gives an inline field (Enter or ✓ commits, blur does not);
the panel commits per keystroke, 400 ms debounced in the reader → blanking it never deletes,
only the trash button does.
**Set a NAG** — press a glyph → it replaces any other quality NAG, toggles off when pressed again.
**Copy** — "Copy Whole Line" (SAN only), "Copy PGN from Here" (subtree with comments, NAGs and
variations), "Copy Game PGN" (verbatim), "Copy mainline PGN (no comments)", "Copy FEN" → each toasts.
**Flip the board** — `F` → sticks for the following games until a player perspective is chosen.
**Engine on/off** — the switch or `E` → off abandons the search, keeps the process warm and is
remembered across launches; on analyses the current position, never the one it stopped at → during
a build, "Stockfish is busy building your repertoire. Pause the build or wait for it to finish
before using engine analysis."
**Change cores / memory / depth / lines** — typeable steppers → "Saved engine changes apply to the
next search or job."; a storage failure says "Preferences were not saved."
**Show threat / click a PV move** — threat analyses with the turn passed and en passant cleared and
a PV click adds that line as scratch moves → threat is silently disabled in check or at game end.
**Switch explorer database** — the table reloads and the choice is remembered → "Could not reach
the Lichess explorer.", "Lichess is rate-limiting requests.", "No games found for this position.",
or a Lichess login prompt on a 401/403.
**Add an explorer move** — clicking a row only plays it; right-click → "Add {san} to repertoire" →
"Added {san} to repertoire", or "Failed to add {san}: {error}".
**Set up a position** — a spare click takes a brush that paints across squares, right-click clears
one, the primary button hands the position over → refused on an unapplied FEN draft ("Apply or
discard the FEN text before using this position.") or an illegal setup ("Each side needs exactly
one king.").

## Data
- **The document** is the PGN. Editors show prose only and re-attach every `[%…]` token on save, so
  a round trip must keep `[%eval 1.23,18]` (pawns, optional depth), `[%pv]`, `[%bestline]`, `[%clk]`,
  `[%cal]`/`[%csl]`, `[%tstart]`/`[%tend]`, and the generated-metric tokens `[%maia]`, `[%maiatop]`,
  `[%maiaProbability]`, `[%humanFrequency]`, `[%engineReply]`, `[%chessDbMove]`, `[%expectimax]`,
  `[%onlyMove]`, `[%myEase]`, `[%ease]`, `[%score]`, `[%games]`, `[%lastPlayed]`, `[%loss]`,
  `[%transposes]`, `[%cumProb]`, `[%importance]` — all hoisted to the comment's front today.
- **Engine cache** — SQLite `evals(fen, eval_cp_white, depth)` keyed by the 4-field FEN, White-
  relative, deepest wins, written 500 ms or 200 entries after a completed non-threat search; the dock
  writes it and never reads it, while generation, bulk review and tactics read it.
- **Settings** are global across every board: cores, memory, depth, lines, coordinates, piece
  notation, show legal moves and engine on/off (default on).
- **Explorer sources** — Lichess masters and player databases over HTTPS: 100 ms minimum gap, 3
  retries, 60/120/240 s backoff on 429, 250 ms leading-edge debounce, no request past ply 50 or after
  3 empty answers going deeper; cached in memory only (2000 entries, no TTL, no disk). TWIC answers
  from a local SQLite book with no network; ChessDB is a separate dock source over HTTP.
- **Explorer offline** — decided: the Lichess database stays online-only and its cache stays in
  memory. With no connection the dock says `Could not reach the Lichess database — it needs a
  connection.`, names TWIC when the user has it, and offers **Try again**; it never shows an empty
  table or a spinner that cannot resolve. This is the one exception to "what a panel displays is
  persisted" in [Network and offline](../../ARCHITECTURE_RENEWAL.md#network-and-offline).
- Builder, PGN Viewer, Study, Trainer and Tactics all read and write this, and share the engine
  process and search budget with tree generation.

## Keep / Change / Drop
Keep — Board
Keep — Square feedback
Keep — Arrows and circles
Keep — Eval bar
Keep — Move list
Keep — Comment panel
Keep — Engine dock
Keep — Explorer (Database dock)
Keep — Board editor
Keep — Move a piece
Keep — Promote
Keep — Play a move
Keep — Promote a variation
Keep — Delete from a move
Keep — Edit a comment
Keep — Set a NAG
Keep — Copy
Keep — Flip the board
Keep — Engine on/off
Keep — Change cores / memory / depth / lines
Keep — Show threat / click a PV move
Keep — Switch explorer database
Keep — Add an explorer move
Keep — Set up a position
Keep — The document
Keep — Engine cache
Keep — Settings
Keep — Explorer sources

Quirks worth a verdict:
- Two independent move lists: 18px vs 24px indent, folding vs none, 900px column vs pane-width.
- Promote, make-main-line and delete-a-saved-variation exist only in the editor; a new move at a
  branch point becomes the *last* variation, and no move list sees a transposition.
- Two comment-committing models disagree on whether blanking deletes.
- "Show legal moves" is off by default, and with no eval bar the score lives in the engine gutter.
- The explorer shows no average rating or performance though TWIC stores it, and "Comment current
  move" has no key on any of its three screens. Its cache never expiring or reaching disk is
  deliberate — see **Explorer offline** above.

## Decisions (owner, 2026-09-22)
- **Keeping the UI clean.** A new capability is a tab on the reading card or a source behind an
  existing tab's gear, never a new dialog, dock or top-level control. Each tab owns at most one
  control at the strip's right edge (`Next gap` on Replies, the gear on Explorer); configuration
  lives behind it, never on the page. A dialog asks one question and closes; anything with more
  than three fields is wrong. The old app's import form (a tagline, a name, a colour switch, a
  paste box and two paths in one dialog) is the example of what not to build.
- **The explorer is a tab**, as lila's book button swaps the move list for the explorer in the
  same column: `Moves | Replies | Explorer`. The only new control on screen is the tab. Its gear,
  at the strip's right edge, holds the source and that source's chips: `Masters`, `Lichess`
  (speed and rating chips), `TWIC` (`Classical OTB only`; the one source that works offline, and
  only with a local master database), `This file` (the games the viewer has open) and `My games`
  (the player-analysis corpus). Under the strip one muted line summarises the choice
  (`Lichess · blitz rapid classical · 2000+`) and clicking it opens the gear. The body is the
  table — move (ticked when the chapter plays it), games and share, the white/draw/black bar, a
  `Σ` totals row — and the games list under it, which opens a game in the PGN Viewer at that
  position. Clicking a row plays the move; on a repertoire chapter playing saves, so there is no
  `Add to repertoire`. No sorting. The old viewer's `Tree` tab is the `This file` source, not a
  tab of its own. Offline the Lichess sources say so with `Try again`, as decided above.
- **The settings gear sits at the right end of the top bar**, the old app's place, and is the one
  way in besides Ctrl+,; the mode menu lists modes only.
- **No eval bar** (question 1; the viewer's decision of 2026-09-21). **One move list** for reading
  and editing, the reading card (question 2). **Esc cancels a promotion** (question 6).

## Questions for the owner
1. Should the workspace say so when a played move already exists or forks a line?
2. Should `[%…]` tokens keep their place in a comment instead of being hoisted to the front?
3. Should the explorer table carry lila's average-rating column beside the bar?
