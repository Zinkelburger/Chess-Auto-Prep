# Repertoire trainer

Status: implemented in v2 as the **Repertoire trainer** mode and as the
**Train** tab on the Repertoire builder's reading card. The mode lists the
repertoires on the left and pins Train first on the card, with Moves and
Explorer beside it; the builder's Train tab is the same trainer. A PGN
opened or pasted in the trainer becomes a repertoire and stays there.
Owners: `lib/features/trainer/`, `lib/chess/training/`,
`lib/storage/training_store.dart`.

## Import and choose lines

In Repertoire builder, open **Train → Import course PGN…** (also offered in
**Training actions** when a chapter is open). Choose a PGN from Downloads.
The normal repertoire importer copies it into the library, retains course
chapters and notes, and expands variations into individual trainable lines.
The import opens on Train. The downloaded original is unchanged. A course
whose playing side cannot be inferred asks for it; Actions → Play as White /
Black changes the stored repertoire side later.

Choose a chapter in the library, then **Chapter**, **Repertoire**, or **Book**
for the scope. Book includes every chapter selected in the active book.
Search matches line names, chapter names and moves. The list offers Training
order, Course order, and Most likely first when probability tags are present.
Completed/model games can be read but are never drilled; excluded lines keep
history and stay out of queues until included again.

Players → **Train group study** selects Chapter scope and trains every chapter
of the linked study, retaining each chapter's `Orientation`. Reading a line
opens that study game at the requested move. Studies with a playing side on
every chapter can also use the shared trainer; other files opened game by game
are not trainable.

## Learn and review

- **Learn** takes new lines (10 by default). Each of your moves is shown, then
  taken back for you to play; the whole line follows as a quiz. New lines are
  rated automatically: Good after a clean quiz, Again after mistakes.
- **Review** takes due lines, oldest due first (all by default). Play from
  memory. The line is graded from its mistakes, as Chessable grades it: Good
  when every move was right, Again when any was missed (a forgotten move
  must come back soon; Hard would still lengthen the interval). With
  **Rate reviews myself** on, the line instead waits for Again, Hard, Good
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
Nothing beyond the shown moves is printed in the lesson move list. The chapter
outline is hidden while the lesson owns the board, so its previews cannot
reveal answers; it returns when the lesson finishes or is left. For the same
reason every other card tab (Moves, Replies, Explorer, Search) reads
`Hidden while training` until then.

**Space** advances a learning step or takes the offered grade, **1–4** rate,
**↓** skips, **Escape** returns to the list. Skip and Restart line are available during the lesson,
and its **Line actions** menu (`⋯`) offers **View moves and notes** — the
whole line with its comments, read-only, until Hide — and **Exclude from
training**, which takes the line out through the normal training records
and goes on to the next. The recap
shows completed lines and right/wrong answers. Leaving before rating leaves
the line's schedule unchanged; accepted writes remain owned by the app.

## Settings and progress

**Training actions → Training settings…** opens the Training settings group.
The app settings also contain it. New-line and review limits accept
0 for all lines; reply delay is 200–2000 ms. Replay missed moves and Rate
reviews myself are optional. Preferences persist in the existing settings file and
are captured for a sitting, so changing them does not alter an active lesson.

The list shows learned/due/untrained/excluded counts. Per-line actions read a
line, open it in Builder, mark it known/untrained or include/exclude it. Bulk
marking acts on the scope. Mistakes are searchable and open their position.

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
