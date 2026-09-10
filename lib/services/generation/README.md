# Generation module map

For Pure expectimax semantics, assumptions, and verification, see
[the shared algorithm contract](../../../docs/ALGORITHM.md).

The standard builder dispatches to `PureTreeBuilder`. `pure_position.dart`
provides legal moves and path-dependent terminal outcomes. `ExpectimaxCalculator`
and `RepertoireSelector` use a single maximizing scorer. `LineExtractor` preserves
the resulting history-dependent policy. `BuildRun` owns cancellation, the
stopwatch, providers, node allocation, and progress. `tree_serialization.dart`
persists the model and explicit completion/bounds.

`node_expander.dart`, `FrontierQueue`, coverage sweeping and book expansion remain
for separate database modes and legacy tooling. They are not the Pure algorithm.
Retired preference fields remain readable in legacy configuration, but the Pure
builder/scorer ignore them and the Pure form does not expose them.

On-demand probes use the same build service. Reusing an old Pure subtree as a new
root restarts construction because repetition history and horizon have changed.
Pure's engine depth replaces the old mixed-depth verification pass.

## Course composition (`course/`)

A repertoire tree flattened into root-to-leaf paths is what a machine wants
and not at all how a person studies one. Phase 3.5 re-imposes the structure
the flattening destroyed:

| File | Job |
|---|---|
| `chapter_planner.dart` | Cut the line list at branch points until every chapter is between `minLinesPerChapter` and `maxLinesPerChapter`. Branches too small to be chapters are swept into one "rare sidelines" bucket. Pure list surgery — no chess. |
| `opening_namer.dart` | Deepest ECO-book hit along a move sequence (FEN-keyed, so transpositions name correctly), plus move-reference formatting (`6.Be3` / `6...Bg7`). |
| `chapter_titles.dart` | Course title, chapter names, variation names. Strips the opening-family segments every chapter shares — a Maroczy course does not repeat "Sicilian Defense: Accelerated Dragon" twelve times — then disambiguates collisions with the defining move. |
| `model_game_selector.dart` | Picks database games that follow the *selected* repertoire (our moves must be the chosen ones), ranked by follow depth, then result from our side, then rating; round-robins over variations so a course covers its chapters instead of showing six wins in one line. |
| `course_composer.dart` | Assembles everything into `PgnGameSpec`s. |

**Chapters are headers, not variation trees.** Each line stays its own PGN
game and the chapter is named in `[White]`, the variation in `[Black]`, with
`[Result "*"]` — the format `RepertoireService.detectHeaderChapters` already
reads. This is deliberate: `parseRepertoirePgn` follows `mainline()` only, so
folding a chapter's lines into one game with variations would silently reduce
the chapter to a single trainable line. Any change here must keep
`course_composer_test.dart`'s round-trip through `RepertoireService` green.

Model games carry `[Result "*"]` for the same reason — a decisive result would
drop them out of chapter detection — with the real game preserved under
`ModelGame*` tags. Those tags are also the *marker*: `RepertoireLine.
isModelGame` reads them back, and the trainer, the deviation walker and
`matchingBookLines` all skip such lines. A model game is somebody else's moves
in a file full of yours — drilling it, or counting it as your book when your
own games are checked, is wrong in both directions.

A model game is annotated at exactly one move: where it leaves the
repertoire. `ModelGameSelector` records the departure while it follows the
game through the tree (`ModelGameDeparture`): if *our* side departed, the
composer writes `{Our repertoire: 10...Qb6}` on the game's move — `… —
improves on 10...Nf6 (+0.35)` when the improvement probe backed that exact
departure — and hangs our mainline off it as a variation; if the opponent
departed, `{Outside the repertoire — prepared here: …}`. The same movetext is
emitted a second time as real games (`ComposedCourse.modelGamePgns`) and the
session controller writes it to `<repertoire>_model_games.pgn` beside the
course, for the PGN viewer; the in-course chapter stays the study copy.

**Nothing writes prose comments.** A generated comment nobody asked for is
noise a reader learns to skip, which costs the annotations that do carry
information (`[%eval]`, `[%maiaProbability]`, …). Where the export used to
explain in words that a line ended because we were already winning, it now
*shows* it: `RefutationProber` asks the engine how the position is won and the
punishment is written as a sideline on the losing move, repeating that move so
it reads as a continuation rather than an alternative. The mainline still ends
where the repertoire ends, so nothing new becomes trainable.

The same prober answers the other question a reader asks — "why isn't the
natural move here?" — in `probeAlternatives`. The tree cannot answer it: our
children are all inside the eval-loss window (default 50cp), so a *refuted*
move of ours was never a child, and their rejected tries sit below the Maia
candidate floor. So the pass brings its own move source (Maia's policy, or the
game database when Maia is unavailable), skips whatever the tree already
holds, and searches the position after each candidate. Only a move that costs
the side playing it at least `minLossCp` is written, as an alternative sideline
carrying `?`/`?!` and a `[%loss]` token — a move that turns out to be playable
drops out, because "we don't play this" about a perfectly good move is a lie.
`LineChoice` (from `line_extractor.dart`) is what carries the position, its
best available eval and its known moves out of extraction; it is keyed by FEN
so lines sharing a prefix share one search.

Both passes are capped, deduplicated and best-effort: no engine, no move
source, a cancelled run or a failed search costs variations, never the export.

## Export (`export/`)

`writePgnGame` is the **only** PGN emitter in the pipeline. There used to be
two (`LineExtractor.exportPgn` and `pgn_export.buildRepertoirePgnEntry`) with
separately maintained copies of the annotation logic, which is exactly how
they drifted. `MoveAnnotation` carries everything the tree knows about a move
— eval, ease, naturalness, practical score, recency — and
`MoveAnnotationDetail` decides how much of it reaches the file. Absent fields
are omitted rather than defaulted: an unmeasured score must not read like an
even one.

## The ChessDB mainline book (`BuildMode.chessDbBook`)

A mode with a different bargain from every other one: the database decides,
and nothing in the app is allowed to second-guess it.

- **Our move** is whatever ChessDB ranks best — one child per node, no
  MultiPV, no alternatives, nothing for Phase 2 to choose between. Exact
  score ties (very common: ChessDB scores whole clusters of opening moves 0
  or 25) go to the move with more master games, widened by
  `bookTieBreakWindowCp` if the user asks. With `replyWindowCp` > 0 the
  database gets a second vote before master practice does: each tied
  candidate's resulting position is looked up and the one leaving the
  opponent the *fewest* replies within that window of their best wins
  (`_fewestGoodReplies`) — two level moves can leave one good answer or
  five, and the narrower one is the smaller book. Master practice then
  separates only the candidates that count the same. Those two tie-breaks
  are the only vote anything but the database's score gets.
- **Their move** is master practice, unsmoothed — `_addOpponentChildrenFrom
  MasterBook(smoothWithMaia: false)`. The Dirichlet prior would add moves
  that are merely plausible, and this book's opponent model is recorded
  practice or nothing.
- **Off master practice, or past `maxPly`,** the fan-out stops entirely and
  the line continues as a single ChessDB mainline. Branching answers a
  *choice*; past practice nobody has recorded a choice, and past the
  branching depth the budget says stop taking them. Either way a
  non-branching line costs one node per ply instead of a fan-out, so `maxPly`
  caps **branching only** — enforced in `expandOpponentMove` — and every line
  runs on to `bookTailMaxPly` (`BuildRun.plyCapAt`). Capping the length at
  the branching depth would cut off exactly the deepest theory the mode
  exists to carry.
- **A line ends where ChessDB's knowledge ends.** That is the default and the
  honest one: the mode promises a database's book, and a move the database did
  not supply is not part of it. `bookEngineFallback` puts the engine
  underneath as a floor for callers who would rather have the line finished —
  it is the only thing that makes `usesStockfish` true here, and it is
  expensive: at depth 30 one unknown position costs seconds where a database
  hit costs a request, so a build with a wide unknown tail spends most of its
  wall clock in the engine and covers far less ground. `BuildStats.
  bookDbMoveHits` vs `bookEngineFallbacks` makes the mix visible and the run
  summary says it out loud, because a book the engine mostly wrote is a
  different artifact and the PGN cannot tell you which you have.
- **Phase 2.5 never runs** (`TreeBuildConfig.runsVerification`). Re-ranking a
  database move by a local search at verify depth would quietly substitute
  Stockfish's opinion for ChessDB's.

The move lists come from `eval/db_move_list.dart` — `ExternalMoveProvider`,
implemented by both ChessDB faces (`lookupMoves`), resolved through
`TreeEvalResolver.lookupBookMoves` (dump → API). That is deliberately a
*separate* chain from `resolveEvalChain`: the sqlite eval database stores
scores rather than move lists and has no answer to give. One lookup returns
the score of every child, so a book build costs one request per **position**,
not per move — the difference between an overnight API run and an impossible
one. The local TerarkDB dump (`tree_builder/CDBDIRECT_SETUP.md`) has no quota
at all and is what a full-encyclopedia build wants.

Chapters for such a book are cut by ECO code rather than by branch point
(`TreeBuildConfig.chaptersByEco`, `ChapterPlanner.ecoOf`): a book spanning the
encyclopedia branches everywhere, and the reader is looking for a code. The
group carries its own `OpeningLabel` because lines reaching one code by
different move orders share a shorter prefix than the code's defining
position.

The board-side Generate pane offers **Build ChessDB repertoire…**. Its form
also offers **Presets → ChessDB compact repertoire**, or **Use compact
repertoire settings** after choosing ChessDB mainline book. This uses
the same method as `test/benchmark/chessdb_book_build.dart`, which produced the
King’s Indian book. The preset keeps one move for our side and limits branching
through master reply count, local reply coverage and branching depth. Root
systems remain broad; line deduplication and folded sidelines keep repeated
decisions out of the training list. Results depend on the position, available
master games, current ChessDB data and build budget; the preset does not promise
a fixed line count or full coverage.

Both the app and the headless harness export the known starting moves before
each generated continuation. For example, `START_MOVES="d4 Nf6 c4 g6 Nc3 Bg7
e4 d6"` builds from the KID position but writes a PGN beginning `1. d4 Nf6`.
The harness records that prefix on its saved tree as well. A custom FEN without
move history stays a setup-position PGN; no move order is invented.

For several systems in one repertoire, use **Generate → Plan starting lines…**.
Enter a move sequence per row, optionally prefixed with a chapter name and `|`.
The board previews and edits the selected row; Add starting position keeps the
others. For example:

```text
Main KID | 1.d4 Nf6 2.c4 g6 3.Nc3 Bg7 4.e4 d6
Fianchetto KID | 1.d4 Nf6 2.c4 g6 3.Nf3 Bg7 4.g3 d6
London | 1.d4 Nf6 2.Bf4 d5
```

**Guided choices** asks setup questions under each root. **Use these positions**
goes directly to chapter review with the ChessDB compact profile. Each root
gets a separate chapter and queued build; budgets are per build point. Roots
must be legal, distinct and not prefixes of one another. Shared setup moves
are preserved in every PGN. This does not imply coverage of systems outside
the supplied roots.
