# Repertoire trainer

Status: implemented in v2 as the **Repertoire trainer** mode and the
builder's shared **Train** tab. The dedicated trainer keeps the app's three
panels: one repertoire outline, the shared board, and adjustable tool panes.
Owners: `lib/features/trainer/`, `lib/chess/training/`,
`lib/storage/training_store.dart`.

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
scopes, line ordering, searchable lines and mistakes. Book includes the active
book's selected chapters. The dedicated trainer offers scoped mistake records
under its training actions.

Players → **Train group study** selects Chapter scope and trains every chapter
of the linked study, retaining each chapter's `Orientation`. Reading a line
opens that study game at the requested move. Studies with a playing side on
every chapter can also use the shared trainer; other files opened game by game
are not trainable.

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

**Training actions → Training settings…** opens the Training settings group.
The app settings also contain it. New-line and review limits accept
0 for all lines; reply delay is 200–2000 ms. Replay missed moves and Rate
difficulty myself are optional. Preferences persist in the existing settings file and
are captured for a sitting, so changing them does not alter an active lesson.

The training home shows learned/total and due counts. Its outline offers
reading and training actions, Learned checkboxes and line pauses. Bulk marking
acts on the scope. The builder's contextual Train tab also offers opening a
line in Builder and searchable mistakes. The dedicated trainer's home lists
mistakes for its current scope without a search field; selecting a mistake
opens its position.

The four existing Documents files remain the source of truth:
`repertoire_reviews.csv`, `repertoire_review_history.csv`,
`repertoire_move_progress.csv`, `repertoire_move_attempts.jsonl`.
SM-2 scheduling and stable line IDs remain compatible with the older app.
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
shared document mutation workflow. The PGN header schedule mirror
is not used.

## Remaining scope

Legacy options for partial-line depth, automatic walkthrough advancement,
per-move streak thresholds and custom chapter grouping are not exposed in v2.
Studies keep their own editing workflow; the group-study handoff uses the shared
trainer without converting the study to a repertoire.
