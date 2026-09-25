# Repertoire trainer

Status: implemented in v2 as the **Train** tab on the workspace reading card.
Owners: `lib/v2/features/trainer/`, `lib/v2/chess/training/`,
`lib/v2/storage/training_store.dart`.

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

## Learn and review

- **Learn** takes new lines (10 by default). Each of your moves is shown, then
  taken back for you to play; the whole line follows as a quiz. New lines are
  rated automatically: Good after a clean quiz, Again after mistakes.
- **Review** takes due lines, oldest due first (all by default). Play from
  memory, then rate Again, Hard, Good or Easy. Again returns the line to the
  end of the Learn/Review sitting.

Sittings fix their set when started. Play on the board or type SAN/UCI in the
move field. The board faces your side and engine analysis pauses while the
sitting holds it. Incorrect moves show the expected move, then play the
correction. Missed quiz moves are replayed at the end unless disabled.
Nothing beyond the shown moves is printed in the lesson move list. The chapter
outline is hidden while the lesson owns the board, so its previews cannot
reveal answers; it returns when the lesson finishes or is left.

**Space** advances a learning step, **1–4** rate, **↓** skips, **Escape** returns
to the list. Skip and Restart line are available during the lesson. The recap
shows completed lines and right/wrong answers. Leaving before rating leaves
the line's schedule unchanged; accepted writes remain owned by the app.

## Settings and progress

**Training actions → Training settings…** opens the Training settings group.
The app settings also contain it. New-line and review limits accept
0 for all lines; reply delay is 200–2000 ms. Replay missed moves is optional. Preferences persist in the existing settings file and
are captured for a sitting, so changing them does not alter an active lesson.

The list shows learned/due/untrained/excluded counts. Per-line actions read a
line, open it in Builder, mark it known/untrained or include/exclude it. Bulk
marking acts on the scope. Mistakes are searchable and open their position.

The four existing Documents files remain the source of truth:
`repertoire_reviews.csv`, `repertoire_review_history.csv`,
`repertoire_move_progress.csv`, `repertoire_move_attempts.jsonl`.
SM-2 scheduling and stable line IDs remain compatible with the older app.
Writes are serialized and conflict checked; unresolved accepted writes offer
retry and block replacing their scope. Chapter/line moves retain progress
through the shared document mutation workflow. The PGN header schedule mirror
is not used.

## Remaining scope

Legacy options for partial-line depth, automatic walkthrough advancement,
per-move streak thresholds and custom chapter grouping are not exposed in v2.
Studies use their own workflow and are not repertoire training material.
The lesson does not yet offer the old Line menu's PGN peek or Builder handoff.
