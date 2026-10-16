# Opening books

Someone preparing for an event makes a named opening book — `Spring Equinox
Open` — out of the repertoires and chapters they mean to play, and puts it in
use. Everything that reads "the book" then reads that one set of lines, and
switching events is switching the book.

Code: `lib/features/books/books_screen.dart` (the mode's screen), wired by
`BooksView` in `lib/app/mode_view.dart`; the owner `Books` in
`lib/workspace/books.dart`, the chip in `lib/workspace/book_chip.dart`;
storage in `lib/storage/book_list.dart` (format), `book_file.dart` (the file)
and `book_references.dart` (selectors rewritten by chapter moves). Back and
Forward live in `lib/app/workspace_requests.dart`.

## Screen

Mode menu: `Opening books` (group `Repertoires`). A screen of its own, no
board. Also reached from the pencil beside the book chip wherever the book is
read.

- **Book list** (left) — `Opening books` with a `+` (`New opening book`); each
  book by name, `In use` under the active one. While chapter moves rewrite the
  books: `Updating book chapters…`. A save problem shows in the error colour
  with `Retry save`.
- **Book editor** (right) — the book's name, `Use this book` (filled) or
  `In use`, and a `Book actions` menu: `Rename…`, `Stop using`, `Delete…`.
  Under it `Search repertoires and chapters`, then every repertoire: a
  tristate box, its name and `2 of 5` chapters; expanded, each chapter with a
  box and `Open in the builder`. Draft chapters are not listed.
- **Empty states** — `No opening books yet.` with `New opening book`;
  `Create or import a repertoire, then choose its chapters for this book.`
  with `Open repertoire builder`; `Nothing matches "q".`
- **Book chip** (elsewhere) — the active book's name (`No opening book set`)
  opens a searchable `Use opening book` list (with no books it goes to this
  mode), and a pencil `Edit opening books` opens this mode at the active book.
  It sits in the explorer's `Book` source, the Train tab, the PGN Viewer's
  `My books` tab and the My games list. Player analysis's `My book` tab has
  `Choose book` into this mode instead.

## Actions

**New opening book** — the `+`, the empty-state button or Actions ▸
`New opening book` → a name → the book opens, empty; it becomes the one in use
when none was → `A book named "X" already exists.`, `Could not make the book.`

**Tick a repertoire** — the whole folder counts, chapters added to it later
included. A part-ticked box ticks the rest; a ticked one takes the folder out.

**Tick a chapter** — that chapter alone (a course chapter by its
`[ChapterName]`). Unticking one chapter of a whole repertoire keeps the others
ticked one by one.

**Use this book / Stop using** — the book in use changes for every reader at
once.

**Rename / Delete** — `Rename opening book`; `Delete opening book "X"?` /
`Its repertoires and chapters stay where they are.` → `That book is no longer
available.`, `Could not rename the book.`, `Could not delete the book.`

**Open in the builder** — opens the chapter in the Repertoire builder.

**Back / Forward** — the arrows in the top bar, Alt+← / Alt+→, or the mouse's
back and forward buttons. A mode switch or a jump into the builder (`Open in
the builder`, a book move's file, My games' open-in-builder) is remembered
with its file and position; Back reopens them. Up to 30 places; the tooltip
names the place.

## Data

- `books.json` in the app's support folder:
  `{version: 1, active, books: [{id, name, repertoires, chapters: [{path,
  section}]}]}`. Paths are relative to `Documents/repertoires/`, with `/`
  between parts and never a `\`.
- Written whole and atomically after each change, one write at a time; edits
  not yet taken are replayed on what the file holds when another writer
  changed it first.
- Fail open: a file that cannot be read, or has an unknown version, is
  reported (`Your books could not be read.`) and never written over; it never
  blocks renaming, moving or deleting a chapter, repertoire or study. Entries
  it cannot read are left out of the list, and before an edit would write them
  out a copy of the old file goes to recovery quarantine.
- Renaming or moving a chapter or repertoire in the builder, and renaming a
  course chapter, rewrite the selectors.
- Read by: the explorer's `Book` source, My games, the PGN Viewer's
  `My books` tab, the Repertoire trainer's book scope, Player analysis's
  `My book` tab.

## Owner decisions

- **One book in use** (2026-09-23): a book is a named set of repertoires and
  chapters for one event; exactly one is in use at a time and every reader of
  "the book" reads it. One book holds both colours; each chapter says its side.
- **No designated per-colour book paths** (2026-09-23): books replace them.
