# Study

Study keeps annotated chess material in named chapters. It uses the shared
board, move tree, engine, document session and autosave system. The current
implementation is under `lib/features/study/`; this document describes the
shipped controls rather than the retired V1 screen.

## Navigate and organize

The sidebar has two views: a searchable **Your studies** picker, and the
current study's searchable chapter list. **All studies** returns to the picker.
Chapter names have full-name tooltips, the active chapter is highlighted and
revealed on selection, and filtering preserves the original chapter ordinals.
Drag an ordinal to reorder when the search is empty; **Move to position…** in
the chapter menu also supports long-distance moves without dragging. Reordering
keeps the current chapter selected and is undoable.

**New study** creates a file with one chapter. **New chapter** supports the
initial position or the shared position editor. The chapter menu provides
rename, PGN tags, starting position, board orientation, reordering,
copy PGN, clearing annotations/variations and deletion. Changing a starting
position or clearing material asks for confirmation. The last chapter cannot
be deleted. The study menu provides rename, export, copy and deletion, plus
retained save/rename retries when needed.

## Import and export

**Import…** has three sources: PGN file, pasted PGN, and a Lichess study/chapter
URL. Reading a source produces a chapter-count preview before any write. Choose
a new study or the current study; the destination is captured when the dialog
opens. Failures retain the typed source and explain how to retry. A replacement
file read clears the previous actionable preview.

New-study import preserves the original PGN text and chooses a free filename.
Appending adds complete games through the open document session, preserving
unsaved edits and making the addition undoable. It selects the first appended
chapter. Partially parsed PGN can be preserved as a new file when it contains
at least one complete game; it cannot be appended through a lossy rewrite.

**Copy study PGN** and **Copy chapter PGN** export the respective material.
**Save study PGN as…** writes a captured snapshot to a chosen folder and never
overwrites an existing file. Other modes use the shared **Add to study** picker
and the same append command.

## Annotate and train

**Annotate** above the moves opens the shared comment editor; **Ctrl+E** toggles
it. A move's menu includes **Comment this move** and can be opened by right-click,
Shift+F10, or the context-menu key while its move token is focused. Move-quality
glyphs and positional evaluations are separate groups, so choosing `±` keeps
an existing `!`. Comments retain embedded clocks, engine values and shapes.
At a move, visible **Quiz starts here** and **Quiz ends here** toggles control
the same `[%tstart]` / `[%tend]` tokens as the move menu.

**Train study** opens the shared trainer inside Study. Choose **This chapter**
or **Whole study**. **Training sides…** assigns each chapter's practice side,
with **Set missing to White/Black** for bulk setup and individual overrides.
These choices are one undoable document edit and do not flip the board.
Configured chapters remain trainable when other chapters lack a side. Incomplete
games are excluded from study training.

Practice side comes from `[TrainingSide "white|black"]`, falling back to a valid
imported `[Orientation "white|black"]`. Missing or invalid metadata requires a
choice; the board's visual default is not silently treated as a training side.
The trainer honors quiz ranges and retains the selected scope after edits.
This is line practice, not Lichess interactive-lesson authoring.

## Save and recover

Edits use the shared session and autosave owner. Save state appears in the edit
strip; failures offer the existing retry, copy or reload paths. Save and status
messages expose live-region semantics. Chapter selection is exposed semantically
as well as visually.

Deleting a study moves its PGN into `.cap-pgn-history` below the studies folder.
**Deleted studies** remains visible at the foot of the sidebar, including when
the active list is empty. It lists recoverable files with **Restore** and
**Restore as…**. Name collisions never overwrite a current study. Unconfirmed
restores retain the original operation/revision and offer **Retry restore**,
even when the source recovery file has already moved. Restoring refreshes the
study list without taking the user away from the current document.

Rename preserves the file's PGN bytes. Player/group prep links must be updated
before a linked study can be renamed or deleted. Restoration, rename, deletion
and imports use the document store, shared recovery gate and pending-write
tracking; widgets do not write files directly.

## File format and remaining scope

A study is one PGN under `Documents/studies/`, with one game per chapter.
Study metadata uses `Event`, `StudyName`, `ChapterName`, `Orientation`, and
`FEN`/`SetUp` for custom starts. Explicit practice choices add `TrainingSide`.
Unchanged chapters keep their original text, while edits refuse incomplete
content that cannot be safely rewritten. Undo and recovery use the shared V2
storage system.

Lichess collaboration, member permissions, chat, publication/discovery, and
interactive lesson authoring are outside this local study editor. This work
improves local authoring and practice usability; it does not claim full parity
with the Lichess study service.

## Verification evidence

The 2026-10-03 usability pass used a headless Linux production build at
1280×720 with a disposable profile and a synthetic three-chapter Queen's Gambit
PGN. The walkthrough covered pasted import, side setup, chapter-only training,
annotation, narrow-pane layout, drag reordering, and delete/restore. The native
preview was stopped after inspection. Automated coverage also exercises the
276px annotation strip, keyboard move menus, partial imports, stale previews,
unsaved edits, hidden-field validation, restore collisions and retained retries.

Screenshots: [import](../../../.impeccable/review/study-usability/study-import.png),
[side setup](../../../.impeccable/review/study-usability/study-sides.png),
[training](../../../.impeccable/review/study-usability/study-training.png),
[annotation](../../../.impeccable/review/study-usability/study-annotate-final.png),
[narrow pane](../../../.impeccable/review/study-usability/study-narrow-final.png),
[recovery](../../../.impeccable/review/study-usability/study-recovery.png).
All captures are app-rendered evidence using repository assets, not mockups.
The isolated profile's unconfigured online explorer returned HTTP 401; no live
Lichess download or online-explorer success is claimed by this walkthrough.
