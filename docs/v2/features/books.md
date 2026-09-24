# Books

Status: built from the owner's request (2026-09-23), not yet corrected by the owner
Old code (oracle only): none — the old app's per-colour "designated book" paths
Plan step: 9c

## Purpose
Someone preparing for an event makes a named book — `Spring Equinox Open` — out of the repertoires
and chapters they mean to play, and puts it in use. Everything that reads "the book" then reads that
one set of lines, and switching events is switching the book.

## Screen
Reached from the mode menu (`Books`, after Repertoire builder) and from the pencil beside the book
name wherever the book is read (the explorer's `Book`, the My games column, the Train tab's `Book`
scope). A screen of its own, no board.

- **Book list** — left column, `Books` with `New book`, each book by name, `In use` under the one in
  use. A click opens it on the right.
- **Book editor** — the book's name, `Use this book` (filled) or `In use`, and a `⋯` menu with
  `Rename…`, `Stop using` and `Delete…`. Under it `Search repertoires and chapters`, then every
  repertoire: a box (ticked, part-ticked or empty), its name and `2 of 5` chapters; open to show its
  chapters, each with a box and `Open in the builder`. Draft chapters are not listed.
- **Empty** — `No books yet.` with `New book`; `No repertoires yet.`; `Nothing matches "q".`
- **Book chip** — elsewhere: the book in use by name (`No book set`), which opens a typeable
  `Use book` list, and a pencil (`Edit books`) into this mode.

## Actions
**New book** — the button or Actions ▸ `New book` → a name → the book, empty, open; it is in use
when none was → `A book named "X" already exists.`
**Tick a repertoire** — the whole folder counts, chapters added to it later included. A part-ticked
box ticks the rest; a ticked one takes the folder out.
**Tick a chapter** — that chapter alone (a course file's chapter by its `[ChapterName]`). Unticking
one chapter of a whole repertoire keeps the others ticked one by one.
**Use this book / Stop using** — the book in use changes everywhere at once.
**Rename / Delete** — the repertoires and chapters are untouched.
**Back / Forward** — the arrows at the left of the top bar, Alt+← / Alt+→ and the mouse's back and
forward buttons. A mode switch or a jump into the builder (a book's `Open in the builder`, a book
move's file, My games' `Open in builder`) is remembered with the file and position; Back reopens
them. Up to 30 places; the tooltip names the place, `Back to My games`.

## Data
`books.json` in the app's support folder: `{version, active, books: [{id, name, repertoires,
chapters: [{path, section}]}]}`, paths relative to `Documents/repertoires/` with `/`. Written whole
and atomically after each change. A file that cannot be read is reported and never written over.
Renaming or moving a chapter or a repertoire in the builder, and renaming a course chapter, rewrite
the paths. Read by the explorer's `Book`, My games and the trainer's `Book` scope.

## Keep / Change / Drop
Keep — Book list
Keep — Book editor
Keep — Book chip
Keep — Back / Forward

## Questions for the owner
- Should a book be pickable per mode, or is one book in use enough?
