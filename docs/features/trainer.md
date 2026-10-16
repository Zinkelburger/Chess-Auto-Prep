# Repertoire trainer

Someone with a repertoire or a downloaded course opens the **Repertoire
trainer** (mode menu, Repertoires group) to learn new lines and review due ones
from memory; they leave with spaced-repetition progress saved per line. The
same trainer is the **Train** tab in Repertoire builder and Study. The mode has
the app's three panels: one repertoire outline, the shared board, and
adjustable tool panes.

Code: `lib/features/trainer/` (`Trainer` scope/loading in `trainer.dart`,
`TrainingProgress` in `progress.dart`, `Lesson` sitting in `lesson.dart`),
pure rules in `lib/chess/training/` (`schedule.dart` SM-2, `drill.dart`,
`sitting.dart`, `line_order.dart`), files in `lib/storage/training_store.dart`,
`training_progress.dart` and `training_rows.dart`, the mode in `lib/app/mode_view.dart` (`TrainerView`).

## Choose a repertoire and scope

The left panel has a searchable repertoire switcher and **Import course PGN…**.
The trainer remembers its repertoire in settings, independently of the file
being read on the board. It opens on the whole repertoire, so **Learn** starts
at the first unfinished line without a chapter or line selection. Import uses
the normal guarded repertoire importer and leaves the downloaded original alone.

The outline expands chapters and lines. A chapter selects its training scope;
a line selects its scope and previews its moves on the board without starting
a quiz. **Whole repertoire** returns to the broad scope. Each level offers
Learn and Review. Line checkboxes mark known material **Learned**; row menus
also offer reading and training. Model games and lines with no moves to ask
remain read-only and never enter queues.

**Review → Due / All learned / Choose lines** controls the next review.
Choose lines changes the outline checkboxes into session selection; the same
selection also narrows Learn to new lines. Review of an explicitly selected
line is available before its due date. Due/All learned and manual-rating
preferences are remembered; temporary selections are not.

**Pause line training** preserves the line's history. Chapter and repertoire
pauses are remembered separately and cover newly added lines as well. Resuming
a parent keeps individually paused children paused. Learned checkboxes change
knowledge without clearing a pause. **Stop for now** ends the current sitting;
completed progress is saved, and the next Learn skips completed lines. An
unfinished line starts again after an app restart.

The builder's contextual Train tab retains Chapter, Repertoire and Book
scopes, line ordering (training order, the file's order, or most likely first
from a generated chapter's `CumProb`), searchable **Lines** and **Mistakes**.
Book includes the active book's selected chapters.

In Study the Train tab offers **This chapter** / **Whole study** and
**Training sides…** (see [study.md](study.md)); a chapter's side comes from
`TrainingSide`, else `Orientation`, and a chapter with neither is left out until
one is chosen. Players → **Train group study** opens the group's study in Study
(creating `Prep – {group}` from the members' prep studies when the group has
none) with **Whole study** selected. Reading a line opens that study game at the
requested move.

## Learn and review

- **Learn** takes new lines (10 by default). Each of your moves is shown, then
  taken back for you to play; the whole line follows as a quiz. With automatic grading, new lines receive Good after a clean quiz and Again
  after mistakes. **Rate difficulty myself** instead asks for a rating.
- **Review** takes due lines, oldest due first (all by default). Play from
  memory. The line is graded from its mistakes, as Chessable grades it: Good
  when every move was right, Again when any was missed (a forgotten move
  must come back soon; Hard would still lengthen the interval). With
  **Rate difficulty myself** on, the line instead waits for Again, Hard, Good
  or Easy, Anki's way, each showing its interval; the mistakes' grade is the
  filled button and Space takes it. Again returns the line to the end of the
  Learn/Review sitting.

A study's quiz markers narrow a line: the moves before the one marked
**Start quiz from this move** (`[%tstart]`) play themselves, and the drill
stops after the one marked **End quiz after this move** (`[%tend]`). A
line without markers is drilled whole; an end marked before the start is
ignored.

Sittings fix their set when started. Play on the board or type SAN/UCI in the
move field. The board faces your side and engine analysis pauses while the
sitting holds it. Incorrect moves show the expected move, then play the
correction. Missed quiz moves are replayed at the end unless disabled.
Nothing beyond the shown moves is printed in the lesson move list. Other
answer-bearing panes start concealed. **Study position**, or **Reveal help and
study** in an adjacent pane, suspends the lesson and opens a scratch copy of
its line at the current position. Analysis and Explorer can then be used
alongside Train, with the normal database choices and resizable pane controls.
The dedicated trainer's Analysis tab is its only engine surface and uses the
shared engine on that board; exploration never edits the repertoire.
**Return to training** restores the
retained lesson position and conceals answers again. Engine startup failure
stays in the normal engine controls and does not prevent returning.

A tab picked from `+` while the card is one pane opens under the lesson, as in
the PGN Viewer. The lesson fits that half of the card: the heading, prompt,
control and footer keep their places, the moves so far take the height left
and keep the latest move in view, and a short pane drops the rating question
over the four buttons. A pane too short for even that scrolls whole.

**Space** advances a learning step or takes the offered grade, **1–4** rate,
**↓** skips, **Escape** returns to the list. Skip and Restart line are available during the lesson,
and its **Line actions** menu (`⋯`) offers **View moves and notes** — the
whole line with its comments, read-only, until Hide — and **Pause line training**, which takes the line out through the normal training records
and goes on to the next. The recap
shows completed lines and right/wrong answers. Leaving before rating leaves
the line's schedule unchanged; accepted writes remain owned by the app.

## Settings and progress

**Training actions → Training settings…** opens the **Training** group of
Settings. **New lines per sitting** (default 10) and **Reviews per sitting**
(default 0) accept 0–1000, 0 meaning all lines; **Move delay** is 200–2000 ms
(default 700). Replay missed moves and Rate
difficulty myself are optional. Preferences persist in the existing settings file and
are captured for a sitting, so changing them does not alter an active lesson.

The training home shows learned/total and due counts. Its outline offers
reading and training actions, Learned checkboxes and line pauses. **Training
actions** also holds **Mark scope as learned**, **Mark scope as new** and
**Reload progress**. **Mistakes · n** lists the current scope's mistakes
(`Played … · expected …`) without a search field; selecting one opens its
position. The builder's Train tab also offers opening a line in Builder and
searchable mistakes.

The four existing Documents files remain the source of truth:
`repertoire_reviews.csv`, `repertoire_review_history.csv`,
`repertoire_move_progress.csv`, `repertoire_move_attempts.jsonl`.
Scheduling is SM-2 per line, and line IDs are stable across edits.
The trainer binds progress to the persisted PGN revision and native file
identity from which its moves were loaded. Externally changed or replaced files
must be reopened before training; reloading progress alone cannot authorize
stale moves. Local unsaved edits retain their persisted baseline, and an accepted
workspace save advances that baseline. The store validates that baseline before
accepting each new rating or answer; already accepted commands survive later
saves and follow file moves. Study edits, reorders and deletions pin
surviving line IDs when needed, so their ratings follow the same chapters.
Writes are serialized and conflict checked; a rating that did not save offers
Retry on the lesson and never holds up the next sitting, a reload or a save of
the chapter being trained. Saving, renaming or deleting a chapter never waits
on training: the trainer follows the workspace's own saves and reads the scope
again after anything else. A chapter that cannot be read is left out of a
repertoire or book scope. Chapter/line moves retain progress through the
shared document mutation workflow.

## Owner decisions

- The trainer is its own mode, **Repertoire trainer** (2026-09-25), as well as
  the Train tab in Repertoire builder and Study.
- Reviews are graded automatically from mistakes, as Chessable does: clean is
  Good, any miss is Again (2026-09-25). **Rate difficulty myself** (off by
  default) brings back Again/Hard/Good/Easy with the automatic grade filled.
- The four CSV/JSONL files are the source of truth; the PGN header schedule
  mirror is not written or read.
- Studies keep their own editing workflow; training a study never converts it
  to a repertoire.

## Not built

Checked against `lib/chess/training/` and `lib/features/trainer/`:

- Per-move scheduling — `schedule.dart` schedules whole lines, so one slip in a
  long line makes the whole line Again (Chessable gap).
- Partial-line depth / skip to the first comment — `training_line.dart` drills
  from the line start (or the `[%tstart]` marker).
- A choice of review order — `sitting.dart` `dueNow` always takes the longest
  overdue first.
- Automatic walkthrough advancement, per-move streak thresholds and custom
  chapter grouping — no options in `TrainingOptions`.
