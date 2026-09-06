# Opening book check — how a game is compared with your books

The Games home checks every game against the repertoires designated as
"my books" (Tactics home → Books → Change…) and reports where the game left
them: on each game card, in the Opening review, in the PGN viewer's Line tab
and its banner. This note records the rules the walker follows and why, so
the next person who changes it knows which behaviours were measured and
which were guessed.

The rules were set on 5 Sept 2026 by running one player's 7,537 chess.com
games (Aug 2023 – Sept 2026) against four Chessable course exports:
Vigorito's *Gold Standard 1.e4* (White), Jones' *1.e4 e5*, Vigorito's
*Symmetrical English* short-and-sweet, and Jones' *King's Indian* parts 1–2
(Black). Code: `features/games/services/game_deviation_service.dart`,
`opening_review.dart`, `book_move_keys.dart`; the import side is
`services/repertoire_line_expansion.dart`.

## 1. A book is a set of positions

Every root-to-leaf path of every chapter game is played out and each
position it reaches is keyed by its FEN without move counters
(`positionKey`). A game is in book at a ply when the position after that ply
is one the book reaches by *any* move order. The report is made at the
**last** departure: a game that leaves and transposes back is measured from
the fork it never returned from, and `DeviationReport.gamePathSans` carries
the game's own order when it differs from the book's (`pathSans`).

Measured: with a move-prefix walk, 12% of White games, 15% of games vs 1.d4
and 45% of games vs 1.c4 in the last twelve months left the book and later
re-entered it (median 6–10 plies deeper). Every one of them was reported as
"left book at move 1" or "move 2".

Consequences elsewhere: `pathSans` is the book's order, so the Opening
review groups two move orders into one entry, the builder deep-link finds
the line, and `matchingBookLines` compares positions rather than prefixes.
`[%transposes …]` grafting is no longer needed; a cut line ends on the
position it names.

## 2. A bracket at our own move is commentary

In a course export the mainline of each game is the repertoire. A bracket
at the **opponent's** move is coverage ("if 4...Nd7 then …"); a bracket at
**our** move is the author mentioning what they do *not* recommend
("3.e5 is the Advance — not covered"). The old walker inserted both, so
`3.e5` was "in book" and the verdict for the Advance Caro-Kann was "Book
ends at move 4" — for a third (132 of 387) of the sample's White games.

Import writes a `[BranchPlies "…"]` header on every expanded sideline (the
plies where the path left the first-child path); `RepertoireLine.
firstBranchOnSide` reads it back. The walker records such moves as the
node's *alternatives* and does not follow them; a game that plays one gets
"You left book: 3.e5 (book 3.Nc3)" with `mentionedAlternative = true`. The
Line tab's book pane skips these lines too — otherwise the Caro-Kann fork
listed ninety-three one-move "— 3.e5" stubs, all "ends".

Measured: the rule changed nothing for the two exports that carry no
brackets (Jones' e5 and KID), and it also removes the course introduction's
anecdotes (a 1.d4 Nimzo story in a 1.e4 course) from the book, since they
are brackets at White's first move.

Hand-built chapters: a single game with two of our own options in brackets
is now read as "the first is the repertoire, the second is mentioned". Put
genuinely alternative lines in separate games (the builder already does).

## 3. Names, gaps and wording

- **Name the line, not the file.** An imported course is one chapter file,
  so every verdict used to read "The Gold Standard 1.e4 - IMC · move 5".
  Nodes now carry a line title (`DeviationReport.lineName`, e.g.
  "31) Caro-Kann 4...Bf5 › Main Line #3"), preferring a real chapter over
  an "Introduction"/"Quickstarter" line that reaches the position first.
- **The chapter header can be either player, or Event.** See §5; the
  import puts a sideline's branch label on the *title* header, never the
  chapter one, so a sideline no longer becomes a chapter of its own.
- **A "Model Games" chapter is model games.** Course exports mark every
  game `*`, so the chapter title is the only signal; such lines get
  `isModelGame` and stay out of the book (the KID's 2013 Nikcevic–Jones game
  was naming the position after 1.Nf3).
- **An opponent's move the book lacks is a gap, not a fault.** The review
  used to drop opponent deviations entirely. They are the third group,
  "Not in your book", grouped by the move; the home block's
  "Keeps happening" rows include them with the verb *Prepare*.
- **Say the move.** One helper, `deviationVerdict`, gives every surface the
  same line: "You left book: 6.f3 (book 6.Bg5)", "Not in book: 7...O-O
  (book 7...Nc6 / 7...a6)", "Book ends after 12...Rc8".
- **"Checking your books…"** in the Openings block until every game's
  check has run; it used to say the window "stayed in book" meanwhile.

## 4. Cost

A course export expands to one line per variation: the Gold Standard is
1,179 games in the file and 16,285 lines / 25 MB on disk. Building its
position map took ~7 s on the UI isolate — the app froze for that long on
every start. Chapters over 512 KB are now parsed with `Isolate.run`, both
for the walker and for the Line tab's `loadBookLines`; small chapters stay
inline because the widget tests drive them under fake time.

## 5. Import: chapters, duplicates, commentary

- **A course export is split into chapter files at import.**
  `createRepertoire` writes the file, and when its games group by a
  chapter title (`courseChapterHeaderKey`) hands it to `ChapterSplitter`:
  one `.pgn` per course chapter, in course order, titles pinned in
  `[Event]` and a `// Chapter: <title>` preamble line that tells the parser
  the file *is* one chapter (`extractCourseChapter`), so it names lines by
  their titles instead of finding "chapters" in titles that happen to
  repeat. Every verdict then reads "31) Caro-Kann › Main Line #3". Adding
  a PGN to an existing chapter in the builder does not split — that chapter
  was the user's choice.
- **Three header layouts.** The chapter title sits in `[White]` (Jones),
  `[Black]` (Vigorito) or `[Event]` (Jones' KID part 2, with the title
  split over `[White]` and `[Black]`). `chapterHeaderKey` tries all three
  and takes the one whose values come in the fewest contiguous runs — a
  chapter header changes forty-odd times in a thousand games, a title
  header on nearly every one. Counting distinct values instead split
  part 2 into 1,313 chapters.
- **Identical lines are kept once.** The same title with the same moves
  is one line; the Symmetrical English export listed each of its 24 lines
  under all 24 chapter titles and imported as 576.
- **Commentary lines are read, not trained.** `RepertoireLine.isCommentary`
  (a bracket at our own move, from `BranchPlies`) keeps a line out of the
  trainer's scope and the untrained/due counts, labelled "Not recommended"
  where model games are labelled "Model game". It stays in the chapter.

## 6. The book check's own window

The review window ("last 20 games") is what the engine analyses. The book
check reads further back: `GamesWindow.bookCheckGames` (default 200 per
site, Analysis settings → "How many games the book check covers"). The
games fetch is the larger of the two; the list shows the review window,
`RecentGamesController.bookCheckGames` is what the Openings block and the
Opening review aggregate over. Twenty games gave one game per entry and an
empty "Keeps happening"; two hundred is where an opening leak repeats.

## What the sample said about the player (for calibration)

The four books are not what this player currently plays: 1.e4 with 6.f3
against the Najdorf and 3.e5 against the French and Caro-Kann (the book:
6.Bg5, 3.Nc3), the Sicilian rather than 1...e5 (186 of 215 games vs 1.e4),
and ...c5 Benoni structures rather than the King's Indian. Against a book
one does not play the honest report is "left book at move 1" in most games,
and the Opening review's top entries say exactly that — which is the right
answer.

## Not done

- The builder's outline does not yet mark commentary lines the way the
  trainer's browser does; they sit under their title with a "— 3.e5"
  suffix.
- A course imported before this change is still one chapter file. The
  builder's existing "split by course chapters" action does the same job on
  request.
