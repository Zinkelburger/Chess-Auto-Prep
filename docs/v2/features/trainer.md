# Repertoire trainer

Status: draft from the old app
Old code (oracle only): `lib/screens/repertoire_training_screen.dart`, `lib/features/training/`,
`lib/widgets/training/`, `lib/services/repertoire_review_service.dart`
Plan step: 5

No screenshot.

## Purpose
Someone who has built or bought a repertoire drills it: the app plays the opponent, they must find
their own move from memory, and each finished line gets a date to come back on. They leave with the
lines they were shown answered, their schedule written to disk, and a record of what they got wrong.

## Screen
Reached from the mode menu and by handoff from Builder ("Train this chapter"/"Train this line"),
Study and the repertoire library, which may name a file, a chapter or one line. Board and movetext
are the shared workspace, see `workspace.md`; board left, one panel right, stacked 4:6 under 1100px.
The panel is the material list, a load state, the browser or the lesson — the board keeps its place
in all four, idling on the source's first position, oriented to the side the file trains.

- **Repertoire crumb** — app-bar title, `Folder › Chapter` (chapter bold) or `Select repertoire`;
  menu: `Choose repertoire…`, `Reload from disk`, `Open in Builder` (`Edit study…` for a study).
  Beside it the Actions menu, the mode switcher and the settings gear.
- **Scope** (v2) — `Chapter | Repertoire | Book` on the Train tab; `Book` trains every chapter of
  the book in use (`books.md`), both colours, with nothing open, the book chip under it; `No book
  set.` / `Your book has no chapters yet.`
- **Material list** — the shared repertoire library inline when nothing is loaded, plus a `Studies
  — custom tactics` section. Loading: `Reading repertoire…` / `Preparing difficulty order…`; `Retry`.
- **Browser header** — the chapter or file name, `White repertoire` / `Black repertoire`,
  `learned · due · untrained` counts, a back arrow, `Read`, and the only two coloured controls on
  the page: **`Learn`** (`12 untrained`, or `10 lines` when capped; muted `Nothing left to learn`)
  and **`Review`** (`84 due now`; muted `Nothing due`).
- **List toolbar** — `5 chapters` / `12 lines` (`3 of 12 lines` while searching), a sort field
  (`Training order` / `Course order` / `Most likely first`), `Mark lines I know`, and `Search
  chapters` / `Search lines`, matching line names and their moves.
- **Chapter and line lists** — one list at a time: a card per chapter with its counts and `12 lines`
  (leftovers under `Other lines`; skipped when there is one chapter), then per line a name, a move
  preview (auto-played intro prefixed `… `) and `Untrained`, `Due now` / `Due 3h ago` or `Learned ·
  in 4d`. `Excluded` lines and model games offer `Read`. Empty: `No lines here yet.`
- **Mistakes panel** — a searchable log of wrong answers: `Book: 12.Nf3  ·  You: 12.Bd3`, the line's
  qualified name, `Learn` / `Practice` / `Correction`, a relative time; a row reads that line at that
  ply. Empty: `No recorded mistakes.` / `Could not load mistakes.`
- **Lesson panel** — while a line runs: `Back to lines`, `Skip`, a `Line` menu (`View moves and
  notes`, `Restart line`, `Exclude from training`, `Explore position in Builder`, `Copy FEN`), the
  chapter + variation name, `Learning`/`Reviewing`, the phase card, `N lines left in this session`.
- **Phase card** — one status line (`Opening moves`, `Your move`, amber `Play Nf6`, `Practice this
  line · 2 of 3`), then the lesson movetext (only moves already shown, so nothing ahead leaks) or
  the comment on the move just corrected, then a fixed `Next` slot. Under the board a move box
  (`Type a move…`) takes SAN or UCI and submits on a unique legal match.
- **Results panel** — `Line complete!` / `Line complete — with mistakes.` (`Puzzle solved!` for a
  study), `How well did you know this?`, `Last reviewed: 3 days ago`, `Pass: 4 / Fail: 1` and the
  rating buttons `Again` `Hard` `Good` `Easy`, each labelled with what it schedules. One-pass mode
  shows `N lines left in this set.` and `Next line`. While writing: `Saving result…`. When the run
  itself ends: its closing sentence, the session's right/wrong/streak bar, `Back to the line list`,
  `Review 10 more · 84 left` and `Learn 10 more · 920 left`.
- **Chapter prompt** — `Looks like a Chessable course export`, `Sort 412 lines into these 9
  chapters?`, a preview, and `Keep one flat list` / `Sort into chapters`.
- **Training settings** — one form: Practice, Session size, Remembering moves (streak threshold,
  whole line vs first N moves, replay missed moves, rate yourself, review order), Advancing (wait for
  Next, seconds before quiz, auto-next, opponent delay), Opening introduction, Playing side, Chapter
  grouping. Mid-line: `Saved changes apply to your next sitting.`

## Actions
**Choose what to train** — a repertoire, chapter or study from the list or `Choose repertoire…` →
parsed off the UI thread, review rows and per-move streaks read, browser opens → `No trainable lines
found.`, `No chapters with moves to train.`, `Error loading repertoire: <error>`.
**Open a chapter or a line** — a chapter card narrows the list, the counts, both queues and the run
scope until the back arrow widens them; a line row trains that line alone, uncapped, by its own
status — model, commentary and excluded rows open the reader instead.
**Start Learn / Review** — the header buttons fix the sitting's set of lines there and then (the
first `newLinesPerSession` untrained, or `reviewsPerSession` due; 0 = no cap) so finishing a line
cannot pull new ones in behind it. Empty scope: `Nothing left to learn here.` / `All caught up!`
**Watch a new line first** — an untrained repertoire line walks through move by move with its
comments; each of *your* moves waits for `Next`/Space (or `learnDelaySec` seconds), then the board
takes it back and asks for it. Commented opponent moves wait too; then the line restarts as a quiz.
Study/tactics material is always quizzed cold.
**Answer a move** — play it on the board or type it → correct: it plays, the pair holds for
`moveSpeedMs`, then the reply and the next prompt land together → `Could not save this attempt:
<error>` re-arms the board without advancing.
**Wrong move feedback** — the answer is logged, the move's streak resets to 0, amber `Play Nf6`
shows with that move's comment, and after 1.2 s the correct move plays itself; the line carries on
(the learn quiz rewinds and asks again). Each missed move is then replayed alone, `Replay — 2 left`.
**Hint** — no hint button: the wrong-move correction *is* the answer. `Line ▸ View moves and notes`
shows the line's PGN behind `The PGN spoils the line you're training.` + `Show PGN anyway`, warning
`Peeking mid-training — clicking moves here won't touch the training board.`
**Rate and advance** — `Again` / `Hard` / `Good` / `Easy` (keys 1–4) write the schedule; rating is
automatic when `Rate difficulty yourself` is off or the line was just learned (clean → Good, any
mistake → Again). Auto-next then wraps to the next line in the run, else `Next line`. When the run
empties: `That is this sitting's new lines — nicely done.`, `Review session done.`, `Nothing left to
learn here.`, `All caught up!` or `Set complete!` → `Could not save rating: <error>` with Retry.
**Skip, restart or leave** — Skip (or ↓) drops the line from this sitting unrated and unsaved;
`Restart line` replays it from the start, learn walkthrough included if it is still new; `Back to
lines` or Escape rates nothing, flushes pending schedule mirrors to the PGN and returns to the list.
**Exclude from training** — the Line menu or a row action → flagged on disk, out of every queue and
count; re-including keeps its history → `Could not save training progress: <error>`.
**Bulk mark / reset** — `Mark lines I know` puts a checkbox on every row (pre-checked for anything
already trained) with `N checked`, `Save`, `Cancel` and `Check every line you already know. Saving
puts the checked lines on the review schedule; unchecked ones go back to untrained.` Checked lines
schedule 1–3 days out, staggered; unchecked learned lines reset to untrained keeping pass/fail and
exclusion. Only lines visible under the active chapter change; both write a `marked` history row.
**Set the side and the grouping** — Playing side → `From file` / `White` / `Black`, stored per file
and forcing a reload, because a course export says nothing about whose side it is; `Group lines by`
→ file chapters, line-name prefix with a `#` separator, or one flat list. Asked once, never the PGN.
**Read / edit elsewhere** — `Read` hands the chapter's games to the PGN Viewer, `Explore position in
Builder` the exact position, `Open in Builder` / `Edit study…` the source file.
**Keyboard** — Space next learning step, 1–4 rate, ↓ skip, Escape leave the line, `/` focus the move box.
(v2: the move box is the workspace's move field under the board; a move letter typed on the lesson
goes there.)

## Data
Four loose files in the OS Documents root, keyed by `repertoire_id` = the chapter file's path.
- `repertoire_reviews.csv`, one row per line:
  `repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count,excluded`
  (8- and 10-column rows from older versions still load).
- `repertoire_review_history.csv`: `repertoire_id,line_id,timestamp_utc,rating,had_mistake,
  session_type`, append only, `session_type` `trainer` or `marked`.
- `repertoire_move_progress.csv`: `repertoire_id,line_id,move_index,correct_streak,learned`; a move
  is learned at `correctStreakThreshold` (default 3) consecutive right answers, capped there.
- `repertoire_move_attempts.jsonl`: every answer, right or wrong, one JSON object per line —
  `repertoireId, lineId, moveIndex, fen, playedSan, expectedSan, correct, phase, timestampUtc`,
  written immediately: a later correct replay must not erase what was played.
- Saves are optimistic: one that would overwrite another session's edit refuses — `Training progress
  changed in another session. Reload before saving.` The first save keeps a `.pre-csv-v2.bak` copy.
- The schedule is mirrored into each game's PGN headers (`Difficulty`, `Interval`, `DueDate`,
  `LastReview`, `PassCount`, `FailCount`), batched 4 s after the last change and flushed on leaving
  a line. The CSV is the source of truth; headers only seed lines it does not know →
  `Could not mirror training progress: <error>`.
- Following renames: a line with no id header gets a position-derived id, so moving it would orphan
  its progress. Builder and Study pin `[LineID "…"]` into the game first and re-point all four files
  at the new path; a folder or chapter rename rewrites them under their own locks, keeping a
  pre-migration copy under `.cap-reference-history/<operation>/`.
- Scheduling (SM-2): ease starts at 2.5, clamped 1.3–3.0; Again −0.20, Hard −0.15, Good unchanged,
  Easy +0.15. First graduation is 1 day (Easy 3), then Hard `max(current+1, current×1.2)`, Good
  `current × ease`, Easy `current × ease × 1.3`. Again schedules 0 days so the line stays in the
  sitting. Intervals cap at 365 days and take ±5% fuzz (at least ±1 day) above 2 days.
- Preferences: streak threshold 3, depth full line, auto-next on, replay missed moves on, wait for
  Next on (else 3 s, range 1–15), rate yourself on, order `By cumulative probability`, opponent delay
  700 ms (200–2000), start at first comment on, intro delay 600 ms, grouping automatic with `#`,
  new lines and reviews per session unlimited.
- Builder and Study write the PGN files trained here; the generated tree supplies the per-line
  probability behind `Most likely first` / `Hardest to play first`. `Read` opens the PGN Viewer.

## Keep / Change / Drop
Keep — Repertoire crumb
Keep — Material list
Keep — Browser header
Keep — `Learn`
Keep — `Review`
Keep — List toolbar
Keep — Chapter and line lists
Keep — Mistakes panel
Keep — Lesson panel
Keep — Phase card
Keep — Results panel
Keep — Chapter prompt
Keep — Training settings
Keep — Choose what to train
Keep — Open a chapter or a line
Keep — Start Learn / Review
Keep — Watch a new line first
Keep — Answer a move
Keep — Wrong move feedback
Keep — Hint
Keep — Rate and advance
Keep — Skip, restart or leave
Keep — Exclude from training
Keep — Bulk mark / reset
Keep — Set the side and the grouping
Keep — Read / edit elsewhere
Keep — Keyboard

Quirks to rule on: the mode also trains studies as cold tactics puzzles, bringing a second training
mode, a second repetition mode and a second vocabulary (`Puzzle solved!`) onto one screen; progress
is written twice, to CSV and to PGN headers, which disagree after a failed mirror; a line's identity
is its file path plus a move-derived id, so every rename needs a migration pass; rating is silently
automatic for a just-learned line, so the four buttons appear on only some completions.

## Questions for the owner
- Do studies/tactics stay in this mode, or move to Tactics and leave the trainer to repertoires?
- Should the PGN header mirror survive, or is the CSV (plus an export) enough?
- Is "no hint" right, or should a line offer a hint that costs the rating?
- Should the four training files move into the app's data folder, with a one-time migration?
- Does one-pass (linear) mode survive now that Learn and Review are capped sittings?
