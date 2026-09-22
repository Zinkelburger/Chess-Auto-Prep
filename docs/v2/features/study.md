# Study

Status: draft from the old app
Old code (oracle only): `lib/screens/study_screen.dart`, `lib/features/studies/`, `lib/widgets/study/`
Plan step: 4

## Purpose
Someone keeps annotated material — an opening file they wrote, a Lichess study they pulled down, master
games, an opponent's prep file — as named chapters with comments, variations and shapes. They leave with
it edited and saved, exported, or handed to the trainer as puzzles.

## Screen
Reached from the mode menu, from the Repertoire Trainer's "Edit study", and by handoff from any mode's
`Add to study` / `Edit game in a study` (which may name the file, a chapter by index or name, and a line
to park on). Board, movetext reader, annotation panel and engine bar are the shared workspace, see
`workspace.md`. No screenshot.

- **Study title** — the name, clicked to rename inline (Escape cancels, blur or Enter commits); a file
  outside the studies folder shows `<name> (set)` and cannot be renamed. A `▾` opens `Switch study`, a
  searchable list with `N chapters` under each name; empty, `No studies yet — import or create one.`
- **Save status** — quiet, fixed-width, beside the title: `Autosave on · Saved`, `Saving…`, `Not saved`;
  hover gives the path or the failure. Hidden until the study has a file.
- **`Save and recovery…`** — always present (icon only under 960 px), a warning triangle when the last
  write left something to resolve. Opens the shared document save panel.
- **Import chip** — only while a chessgames.com download runs: a spinner, `Importing {done}/{total}` and
  `Stop the download (keeps what has arrived)`. After an unresolved publication, a `Review` button.
- **`Actions` menu** — sectioned: STUDY (`New study`) · IMPORT (`From URL…`, `PGN file as chapters…`) ·
  EXPORT (`Copy study PGN`, `Save study PGN as…`, only with a file) · TRAIN (`Train this chapter`,
  `Train whole study`) · BOARD (`Flip board`) · EXPLORE (`Browse in PGN viewer`) · MANAGE
  (`Delete study…`). Then the mode switcher and the settings gear.
- **Chapter sidebar** (wide, 240 px) — `Chapters (N)`, `+ New chapter`, a `Search chapters` field, then
  one 34 px row per chapter: ordinal (the drag handle), name, the `Result` tag when it is not `*`, and
  a `…` row menu. The active row is highlighted and scrolled into view; filtering disables reordering,
  and no match reads `No matching chapters`.
- **Chapter row menu** — `Edit chapter…`, `Set starting position…`, `Copy chapter PGN`, `Clear comments,
  glyphs and shapes…`, `Clear variations…`, `Delete chapter…` (disabled on the last chapter).
- **Board pane** (centre) — shared board plus the SAN move input, facing the chapter's orientation.
  Shapes drawn on the starting position go into the chapter's introduction comment.
- **Moves pane** (right) — engine bar over the shared movetext editor and annotation panel; clicking a
  move in an engine line plays that line into the chapter as a variation.
- **Compact layout** (< 960 px) — board above, moves below, a chapter bar between them: the chapter name
  opening `Go to chapter`, `+`, and a `Chapter ▾` menu adding `Manage & reorder chapters…`.
- **Chapter manager** — a 520 × 600 dialog with the same list, inline edit/delete buttons, `Open now`
  under the active chapter, the hint `Drag to reorder` / `Reordering is off while searching`, `Done`.

## Actions
**New study** — Actions → a name prompt, refused in the field when nothing filename-safe is left (`That
name has no characters a file can use.`) or on a clash (`A study with this name already exists.`). It
starts with one empty `Chapter 1` and no file until first save.
**Rename study** — click the title or its pencil → the name is sanitised (`<>:"/\|?*` become `_`) and
the file renamed (`A study with this name already exists.`). Refused outside the studies folder.
**New chapter** — `+` → a name (blank = `Chapter N`, or `From the PGN when left blank`), `Start from` =
`Initial position` / `Position` / `PGN`, `Orientation` = `Automatic` / `White` / `Black`. `Position`
offers a FEN box and `Set up board…`; `PGN` takes pasted text where each game becomes a chapter.
`That is not a valid FEN.`, `Paste at least one game.` The new chapter is selected at once.
**Add chapters from a PGN file** — Actions → a `.pgn`/`.txt` picker; every game is appended, named from
`ChapterName`/`Event`/players → `Added N chapters.`, `Could not import that PGN. Your study is unchanged.`
**Add a chapter from another mode** — `Add to study` / `Add line to study` / `Add game to study…`
anywhere opens one picker: an editable chapter name, `Add new study`, and a searchable study list (an
opponent's prep file first, as `Prep file · N chapters`). Writing into the open study goes through the
editor so autosave cannot clobber it; otherwise the file is edited on disk. `Failed to add to study.`
**Reorder chapters** — drag a row's ordinal, in the sidebar or the manager; the chapter being viewed
stays selected wherever it lands. Off while the list is filtered.
**Edit chapter** — row menu → name, `Orientation` White/Black, and a `PGN tags` table (add/remove rows)
for everything the study does not generate: `Result`, `ECO`, `Annotator`, `ChapterURL`, … Refusals:
`A chapter needs a name.`, `Tag names are letters and digits: "{tag}".`, `{tag} is written by the
study; edit it above.` Changing the open chapter's orientation turns the board.
**Set starting position** — row menu → the shared board editor; a chapter with moves first confirms
`Replace starting position?` (`Chapter "{name}" already has moves; … will clear them.`)
**Flip board** — `F` or Actions; this sitting only — only `Edit chapter` changes what is saved.
**Quiz markers** — right-click a move → `Start Quiz From This Move` / `End Quiz After This Move` (and
their `Unmark …` forms). Inline flags in the movetext; they tell the trainer where to start asking
(`training auto-plays the moves before this one and asks for this one`) and where to stop.
**Import from URL** — Actions → a dialog listing what it accepts: `lichess.org/study/<id>` (or
`/study/<id>/<chapterId>`), `lichess.org/study/by/<user>`, `chessgames.com/perl/chesscollection?cid=`.
A fixed-height line echoes the recognised source (`Lichess study · {id}`, `Lichess study chapter ·
{study}/{chapter}`, `Lichess · all of {user}'s studies`, `chessgames.com collection · cid {id}`) or
`Not a Lichess study or chessgames.com collection link.` A checkbox appends to the open study instead
of creating one, disabled for collections (`A chessgames.com collection downloads in the background and
always gets its own study.`) and with nothing open (`No study is open.`). Lichess arrives in one
request with comments, variations and orientation, clocks stripped, the `Study: Chapter` prefix peeled
off the chapter names; the new study opens. Failures stay in the dialog: `Lichess did not respond
(rate-limited or offline). Try again shortly.`, `Study not found. If it is private or unlisted, log
into Lichess first (Settings → Accounts), then try again.`, `Study not found. If it is private, log out
and back in to grant study access.`, `Lichess rejected the request. Log out and back in under Settings
→ Accounts, then try again.`, `No public studies found for “{name}”.`, `Lichess returned HTTP
{status}.`, `That study is empty — nothing to import.`
**Download a collection** — paced: `Seconds between requests` defaults to 22 (`2–3 s apart gets blocked
after ~20 games, 22 s apart sustains 60`); it runs in the background (`Downloading {count} games
(~{minutes} min).…`) and ends with `Imported {count} games into “{name}” ({failed} unavailable).` plus
`Open`. A bot check opens `Collection page blocked`, which offers the collection page and takes pasted
page source, links or bare ids (`{count} games found.`). Also: `chessgames.com is refusing requests.
Downloaded games are cached — start the same collection again later to resume.`, `Downloaded games
could not be saved…`, `The study save could not be confirmed…`, `No free study name was found after 100
attempts…`, `A collection download is already running.`, `Review the previous downloaded study…`
**Save** — autosave writes 2 s after an edit once the study has a file. A failed or unconfirmed write
suspends autosave until an explicit retry, copy or reload through `Save and recovery…`, and tries to
leave a `Recovered …` study beside it. Closing the app unsaved: `This study has unsaved changes or
retained drafts. Save the work you want to keep before closing.`
**Export** — `Copy study PGN` (all chapters, after flushing the save) → `Study PGN copied to
clipboard.`; `Copy chapter PGN` from a row; `Save study PGN as…` asks for a folder and a file name
(`Enter a file name without path separators or reserved characters.`) and writes a snapshot, leaving the
open study untouched — an existing destination is a collision, never an overwrite.
**Clear annotations / Clear variations** — row menu, each confirming counts: `Remove {n} comments and
all glyphs and shapes from "{name}". The moves stay.` / `Remove {n} moves and {m} comments from
"{name}", including sideline annotations. The main line and its notes stay.`
**Delete chapter** — row menu → `Delete chapter "{name}"?` with `Remove {n} moves and {m} comments,
including all annotations.` Refused on the last: `A study needs at least one chapter.`
**Delete study** — Actions → `Delete study "{name}"?` listing chapters, moves and comments, ending `The
PGN file will be moved to Chess Auto Prep recovery trash.`
**Train** — `Train this chapter` / `Train whole study` saves first, then opens the Repertoire Trainer in
tactics mode with each chapter as one puzzle (starting FEN, mainline solution, comments as notes).
`Save the study first (create it by name).`, `No chapters with moves to train yet.`
**Browse in PGN viewer** — saves, then reopens the file as a collection parked on the same chapter; the
viewer's own toggle comes straight back.
**Keyboard** — ←/→ a move, Home/End ends of the line, ↑/↓ previous/next chapter, E engine, F flip, plus
focus-move-input and comment-current-move bindings.

## Data
- One study is one `.pgn` in `Documents/studies/`, one game per chapter; one opened from elsewhere
  (a handoff, a prep file) is read-write but cannot be renamed.
- The chapter format *is* the Lichess study export: `[Event "Study: Chapter"]`, `[StudyName]`,
  `[ChapterName]`, `[Orientation "white|black"]`, plus `[FEN]` + `[SetUp "1"]` for a custom start. Those
  six are owned and regenerated on save; every other tag is preserved per chapter. Names read
  `ChapterName` → `Event` minus the study prefix → `White - Black` → `Chapter N`; orientation without a
  tag is the side to move in a set-up position, else White.
- The chapter introduction is the comment before move 1, stored on the starting position, and shapes
  drawn there live in it. Move comments carry `[%tstart]` / `[%tend]` quiz markers and board shapes as
  tokens, hidden from the displayed prose and surviving any round trip.
- Any edit rewrites the whole file from the in-memory model, so whatever the model cannot hold is lost
  on the next autosave. Restart checkpoints live in `<app support>/study-recovery-v1/`.
- Other modes write here: PGN Viewer (`Add to study`, `Save selection to study…`, solitaire games,
  sideline `Add line to study…`), Tactics (`Add game to study…`), position-analysis scratch lines and
  Players & prep (an opponent's prep file). The Trainer lists studies as `Studies — custom tactics`,
  Players & prep links a study or chapter to a person, and the PGN Viewer opens the same files.

## Keep / Change / Drop
Keep — Study title
Keep — Save status
Keep — `Save and recovery…`
Keep — Import chip
Keep — `Actions` menu
Keep — Chapter sidebar
Keep — Chapter row menu
Keep — Board pane
Keep — Moves pane
Keep — Compact layout
Keep — Chapter manager
Keep — New study
Keep — Rename study
Keep — New chapter
Keep — Add chapters from a PGN file
Keep — Add a chapter from another mode
Keep — Reorder chapters
Keep — Edit chapter
Keep — Set starting position
Keep — Flip board
Keep — Quiz markers
Keep — Import from URL
Keep — Download a collection
Keep — Save
Keep — Export
Keep — Clear annotations / Clear variations
Keep — Delete chapter
Keep — Delete study
Keep — Train
Keep — Browse in PGN viewer
Keep — Keyboard

Quirks to rule on: the last chapter cannot be deleted; the chapter list has two homes with different row
controls; reordering silently turns off while the search box has text; a study *is* its filename; the
whole file is rewritten on every edit, so an unknown PGN construct is deleted rather than kept.

## Questions for the owner
- Is chessgames.com collection import still wanted, given the bot check and the 22-second pacing?
- Does the chapter manager dialog survive, or does the sidebar do everything?
- Should quiz markers stay a hidden right-click action, or become visible chapter-level settings?
- Should a study opened from outside `Documents/studies/` be editable at all, or copied in first?
- Are per-chapter free-form PGN tags worth an editor, or should only `Result` and `ECO` be offered?
