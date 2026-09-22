# Checks

Status: partly superseded (2026-09-21): gaps and coverage are the Replies tab in repertoires.md; the rest is not built
Old code (oracle only): `lib/features/audit/`, `lib/features/holes/`, `lib/features/coverage/`,
`lib/features/traps/`, `lib/services/coherence_service.dart`, `lib/screens/repertoire/`,
`lib/screens/analysis_screen_holes.dart`
Plan step: 8

No screenshot: the app driver was not used for this pass.

## Purpose
Someone with a chapter — written by hand, imported or generated — asks what is wrong with it
before trusting it: which of their own moves lose, which opponent replies have no answer, how much
of real practice it covers. They leave with a ranked list of findings they can step through on the
board, saved beside the chapter.

## Screen
Four tools, reached four different ways; only one is in the builder's Check menu today.

- **`Check` group in the builder Actions menu** — a single entry, `Audit for gaps…`. The chapter
  right-click menu in the outline repeats it as `Audit this chapter`.
- **Audit configuration** — a full-screen route titled `Check this chapter`. A scope line reading
  `Current chapter` or `Subtree from <moves>` with a `Subtree only` checkbox; a sources line
  `Stockfish + Maia` (always on, not a control) with a `ChessDB replies` checkbox (on, "Needs the
  network."); `Max depth (half-moves)` 30 and `Maia rating` 2200 (1100–2900); a `More thresholds`
  disclosure holding `Mistake threshold (centipawns)` 100, `Inaccuracy threshold (centipawns)` 40,
  `Minimum Maia probability` 0.10 and `Strong reply window (centipawns)` 50; a `Repertoire Clashes`
  row with `Add PGN`, a chip per file and `Check against book & course lines` when empty; and
  `Start audit`. Engine depth is not here — it is the global bulk-analysis depth (15, range 1–99).
  Bad input: `Use positive whole-number depths, a Maia rating from 1100–2900, probability from
  0–1, and a mistake threshold above the inaccuracy threshold.`
- **Findings pane** — the builder's bottom pane, `Findings` tab. Header `<chapter> · Subtree · <n>
  positions checked`, the settings summary in its tooltip, `Some checks unavailable` in amber when
  a source failed, then a run error line and the interrupted banner.
- **Filter and status row** — chips `Blunders (n)`, `Inaccuracies (n)`, `Missing (n)`, `Clashes
  (n)` (only with clash PGNs), `Weak (n)`, `Dead Ends (n)`, each losing its count and going dead at
  zero; a `Find a move or line` box; a `Priority` / `Frequency` sort tooltipped `Priority puts
  serious findings first. Frequency uses estimates from repertoire branch counts and source
  probabilities, not measured game frequency.`; `Clear filters`. Below, `<done> / <total> positions
  · <n> findings` while running, else `Top [20] of <n>` with an optional `· ≥ <p> reach` and `·
  <time ago>`, a re-run button (`New audit with different settings`) and `Show/Hide dismissed`.
- **Finding row** — icon, reach probability, a one-line summary over the move path, and a close
  (or undo) button. Summaries read `Mistake: 3. Nf3 loses 120cp (best: Bb5)`, `Missing: 3...Nd4
  (p=12%, 340 games · transposes)`, `Strong reply: 3...Nd4 (ChessDB: equal to their best · 3 good
  moves here)` or `Dead end: 3 uncovered (Nf6, d5, e6)`.
- **Empty states** — `Check this chapter` / `Find weak repertoire moves and missing opponent
  replies. Select a finding to review its line on the board.`, then `No findings match these
  filters`, `All findings dismissed`, `Audit interrupted`, `No positions checked`, `No findings
  from the available checks` or `No issues found in the checked positions`.
- **Preview bar** — above the board when a missing-reply finding is selected: `Missing: <move>
  (preview)` or `Uncovered: <move> (engine-strong, preview)` with `Go to position`.
- **Coverage** — no menu entry: a `Coverage` button on the Jobs pane's idle card and one in the
  Lines browser, both hidden with no master-games database. Its dialog, `Coverage Analysis`, reads
  `Measured against your master-games database: the share of games reaching this repertoire that
  it still answers.` and offers a `Target Threshold` percent box (default 1%, 0–100) and a `Maia
  Fallback` switch with an `Elo:` box (2200, 400–3000), else `Maia is not available on this
  platform.` It has no report panel: a job card, a toast, a summary bar (`Covered: 61.5% |
  Shallow: 23.1% | Deep: 15.4%`) with `Next Gap` and `Biggest Gap`, a `Coverage:` row of `All` /
  `Covered` / `Too shallow` / `Too deep` / `Unaccounted`, a column and dots on the tree.
- **Coherence** — no screen, no controls, no run command. It recomputes itself when a generation
  produces a new tree and surfaces as one sortable `Coherence` column and a `Low coherence` chip
  in the Line metrics view, reached from the outline header's `Line metrics` entry. It compares no
  transpositions and no clashing replies: it mines the *sets* of our own moves across the lines for
  shared patterns. Needs 5 lines; below 0.4 a line is flagged.
- **Traps** — a `Lines (n)` / `Traps (n)` toggle in the same view, present only after a generation
  run, since traps come out of the build and not out of any check. A `<n> traps` header with
  `Start Trap Tour`, `All (n)` / `In Repertoire (n)` filters, `Eval Drop` (default) / `Most Common`
  / `Expected Gain` / `Surplus` sorts, `Expected Trap Value: +x cp/game`, a card with `Show
  Refutation`, `Show Full Line`, `Train This Line`, and a tour bar ordered surplus-first.

## Actions
**Run the audit** — `Audit for gaps…` → the route closes, the bottom pane opens on Findings and
findings stream in live. It walks the chapter breadth-first to the ply limit, charges a reach
probability to every position, asks Stockfish MultiPV 3 about each of our moves, and asks five
opponent-reply sources in fixed order — Lichess (off), Maia, ChessDB, engine MultiPV, clash tree —
where the first to name a move owns it. Transpositions back into the chapter are flagged, not
reported as gaps. A failing source does not stop the run; it adds a line behind `Some checks
unavailable`, such as `Maia is unavailable; common-reply checks were skipped.` A dying run shows
`Audit could not finish. <error>`; a subtree start position that no longer exists produces an
empty report with no error at all, reading `No positions checked`.
**Pause, cancel and resume an audit** — pause and cancel live on the job card only; the status bar
reads `Audit paused`, and cancelling saves the partial report, as switching chapter does.
Reopening the chapter then shows `Audit interrupted at <n> positions (<m> findings)` with `Resume`
and `Start Fresh`; Resume skips what was checked and keeps the earlier findings.
**Open a finding on the board** — click or ↑/↓ → the board navigates to the finding's move path
and, for a missing reply, shows the preview bar. Arrows appear on the board: mistakes red,
inaccuracies yellow, missing blue, at most six at once.
**Dismiss / restore** — the row's X, or a context menu offering `Dismiss`, `Dismiss similar at
this position`, `Dismiss all <kind> at move 3 or earlier` and `Dismiss all <kind>`; `<n> dismissed`
with `Restore all` sits under the list. Each rewrites the report at once — except one made while
the run is still streaming, which is lost.
**Add the fix to the chapter** — no such action: `Go to position` puts the board on the gap and
the user plays the move with the ordinary builder editing.
**Run coverage** — `Coverage` → a job card reading `Root: 12.4K games → Target: 124 (1.0%)`, then
`Found 312 leaf positions` and `Checking unaccounted (120/450)...`. It finds the chapter's root,
counts the master games reaching it, then classifies every leaf `covered`, `too shallow` or `too
deep` (over 4 ply past the first sub-threshold node), or leaves an `unaccounted` opponent move,
falling back to Maia only where the book has never seen the position. It cannot be paused or
cancelled. With no book it refuses: `Coverage needs the master-games database, and none is loaded
— every figure it produced would be zero. Import TWIC issues in Settings, then run it again.`
**Run the merged hunt (holes and tricks)** — not available on a chapter. `Find holes…` in Player
analysis runs it against one player's games. A dialog, `Find Holes`, explains the three finding
kinds, then offers `Max depth (half-moves)` 30, `Maia rating` 2000 and `Moves to probe` 24 (zero
skips the trick search), a `More thresholds` disclosure with `Strong-move window (centipawns)` 30,
`Refutation threshold (centipawns)` 80, `Trick window (centipawns)` 60, `Probe depth (half-moves)`
4 and `Min net gain (centipawns)` 40, and `Start Hunt`. Nothing is validated. It walks from the
*attacker's* side at MultiPV 4, flags attacker moves within 30cp of best that the games never
answer, verifies each refutation with a second search, discovers attacker-to-move leaves
most-reachable-first — the only place it looks past the recorded games — then probes the best
candidates with a short Maia expectimax tree (4 ply, 3200 nodes, 60s each), reporting a trick when
its practical value beats the engine best's raw eval by the net-gain floor. Progress reads `Hole
hunt: Walking 45 / 312 positions`, `Discovery 3 / 24 leaves`, `Probing 8 / 24 candidates`. All
three engine depths are silently the one global bulk-analysis depth, so the "deep verification" is
no deeper than the discovery that raised the finding. Without Maia the trick knobs are hidden and
the status row warns `Trick search skipped — Maia unavailable`.
**Cancel a hunt** — only from the top banner (`Cancelling hole hunt…`), never from the report
panel. The partial report is saved and marked incomplete, but nothing reads that mark back and
there is no resume. A re-run clears the old report first, so a failed run leaves the empty state.
**Read the hunt report** — a flat list ranked by reach × gain, `Uncovered (n)` / `Refutations (n)`
/ `Tricks (n)` chips, `Top [10] of <n>`, `<i> of <n>` stepping, dismissal, and `Re-run`. Empty:
`No hole report yet` with `Find Holes`.
**Export a report** — there is none. Neither report can be copied, printed or written out.
**Keyboard** — ↑/↓ step the active list (trap tour stops while the tour is open, findings
otherwise); dismiss-finding and the trap commands exist with no keys bound.

## Data
- **Audit report** — `<chapter>_audit.json` beside the chapter PGN: findings, stats, percentages,
  the config that produced it, the checked FENs and whether the run completed. Loaded when the
  chapter opens, rewritten on every dismissal and on cancel. A finding of a type this build no
  longer knows is dropped rather than failing the file.
- **Hunt report** — `holes_white.json` / `holes_black.json` under the player's corpus folder in
  `Documents/analysis_games/`, same envelope, `partial: true` when cancelled. The folder name
  includes a fingerprint of the games, so re-downloading a player's games orphans the old report
  rather than updating it — that is the whole retention policy.
- **Coverage and coherence** persist nothing; both are lost when the chapter is reloaded.
- **Sources** — the chapter PGN; the local master (TWIC) book for coverage and its counts;
  Stockfish through the shared SQLite eval cache that generation also fills and reads; Maia for
  opponent replies and trick probes; ChessDB over HTTP; optional clash PGNs (books, courses, or
  one opponent's archive on a named colour). The Lichess explorer is wired but returns nothing, so
  its `min games` 50 and speed/rating settings never apply. One engine job at a time.

## Keep / Change / Drop
Keep — `Check` group in the builder Actions menu
Keep — Audit configuration
Keep — Findings pane
Keep — Filter and status row
Keep — Finding row
Keep — Empty states
Keep — Preview bar
Keep — Coverage
Keep — Coherence
Keep — Traps
Keep — Run the audit
Keep — Pause, cancel and resume an audit
Keep — Open a finding on the board
Keep — Dismiss / restore
Keep — Add the fix to the chapter
Keep — Run coverage
Keep — Run the merged hunt (holes and tricks)
Keep — Cancel a hunt
Keep — Read the hunt report
Keep — Export a report
Keep — Keyboard

Quirks to rule on: the four checks share no home — one menu entry, one Jobs-pane button, one
Player-analysis entry and one column two clicks deep that appears by itself after a build. The
hunt cannot be run on a chapter, though it reads the same tree and writes the same finding model.
Coverage refuses without TWIC and hides its own entry points, so a new user never learns it
exists. Coherence flags a line with no way to ask why. Nothing can be exported, and no finding
writes its fix back into the chapter. The hunt's cancel sits on the top banner rather than in the
report, and its report is readable only from the player it was run for.

## Questions for the owner
- Should the four checks become one `Check` panel over the chapter with one report, or stay four
  tools with four entry points?
- Should the hunt run against a repertoire chapter, not only against a player's games?
- Should a finding write its own fix into the chapter, or is `Go to position` the intended way?
- Should any report be exportable, and should coverage and coherence persist beside the chapter?
- Is the retired Lichess source worth reviving, or should `min games` and the explorer settings go?
- Coverage counts only master games. Should it measure against the user's own opponents instead?
