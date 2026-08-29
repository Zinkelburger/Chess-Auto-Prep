# Performance audit — tree building, repertoire I/O, and tree traversal — 2026-08-28

Read-only audit of every path that builds or walks a move tree: the
generation pipeline (`services/generation`, `tree_build_service`), the
engine pool, PGN parsing and repertoire load/save, and the UI-side controllers
and widgets that traverse `MoveTree` / `OpeningTree` / `BuildTreeNode`.
Compared against lichess-org/mobile (Flutter + dartchess), lila's client tree,
scalachess, and lila-openingexplorer. Every claim carries file:line evidence;
the top findings in each section were re-verified by hand. Sections 0–E are
the audit as written; the **Applied** section at the end records what was
then implemented the same day, and what was deliberately left.

Line numbers are as of the working tree on 2026-08-28 (uncommitted changes to
`opening_tree_widget.dart` etc. included).

---

## 0. The one structural anti-pattern: positions are strings

Every tree node type stores a FEN `String` and nothing else about the position:

- `BuildTreeNode.fen` — `lib/models/build_tree_node.dart:40`
- `MoveNode.fen` — `lib/models/move_tree.dart:110`
- `OpeningTreeNode.fen` — `lib/models/opening_tree.dart:59`

and every helper in `lib/utils/chess_utils.dart` takes a FEN and re-runs
`Chess.fromSetup(Setup.parseFen(fen))` to do one thing: `uciToSanOrNull` (:20),
`sanToUci` (:60), `formatContinuation` (:85), `playUciMove` (:112),
`tryParseFen` (:125), `fenAfterMoves` (:339), `plyReachingFen` (:373). There
are ~70 `Setup.parseFen`/`Chess.fromSetup` call sites in `lib/`, and 84 calls
to `fen_utils.dart` readers that `split(' ')` the FEN (`isWhiteToMove`,
`fullMoveNumber`, `expandFen`).

What that costs in dartchess 0.13.1 (read from
`~/.pub-cache/hosted/pub.dev/dartchess-0.13.1/lib/src/`):

| operation | what it does |
|---|---|
| `Setup.parseFen` | `fen.split(RegExp(r'[\s_]+'))` (setup.dart:34), then `Board.parseFen` builds a new 10-bitboard `Board` per piece (`setPieceAt` in a loop), parses castling against the board, ep, clocks |
| `Chess.fromSetup` | `Castles.fromSetup`, `_validEpSquare`, then `validate()` — king counts, opponent-not-in-check, `_validateCheckers` (position.dart:1033-1043, 658-681) |
| `position.play(move)` | `isLegal` (one `_legalMovesOf(from)` with a fresh context) + `playUnchecked` = one `copyWith` (position.dart:512-520) |
| `position.legalMoves` | **not memoized** — builds a `_Context` (king, blockers, checkers) and a `Map<Square,SquareSet>` on every access (position.dart:193-201) |
| `position.makeSan(move)` | `_makeSanWithoutSuffix` (disambiguation = movegen) + `playUnchecked` + `newPos.outcome` → `isCheckmate` → `checkers` + `hasSomeLegalMoves` on the **child** (position.dart:606-615, 151-164) — i.e. two move generations |
| `position.hashCode` | `Object.hash(board, pockets, turn, castles, epSquare, halfmoves, fullmoves)` — includes the clocks, so `Map<Position,…>` misses transpositions (position.dart:704) |
| Zobrist | none in dartchess |

So "parse a FEN, play one move, take `.fen`" is roughly parse + validate +
movegen + serialize — an order of magnitude more than `parent.position.play(m)`.
None of this matters for one click. It matters when it sits inside a per-node,
per-child, per-legal-move, or per-rebuild loop — which is what the rest of this
document is a list of.

**What lichess does instead.** lichess-mobile's `Node` (`lib/src/model/common/node.dart`)
stores `final Position position` on every node, and `addMoveAt` does exactly
one `parentNode.position.makeSan(move)` to get `(newPos, san)` for the child.
lila's client node (`ui/lib/src/tree/node.ts`) stores the FEN *and* a memoized
`pos()` thunk — parse once on first use, never again; a child added locally
gets `pos: () => Result.ok(pos)` so it is never parsed at all. lila-openingexplorer
keys every position by a 128-bit Zobrist with `EnPassantMode::Legal`, so the
clocks and a non-capturable ep square never enter the key.

**The fix, in order of intrusiveness:**

1. *No model change:* inside every loop, parse the parent once and use
   `pos.makeSan(move)` / `pos.playUnchecked(move)` for children. Applies to
   A3, B4, C4, C7, C8 below.
2. *Additive model change:* add a lazily-populated `Position? _position`
   field to `MoveNode` / `BuildTreeNode` / `OpeningTreeNode` (lila's memoized
   thunk). Nodes created by `play` fill it for free; deserialized nodes fill it
   on first touch. FEN stays for display, keys and serialization.
3. *Key change:* a clock-free `int` position key (FNV-64 over the 4-field FEN
   already exists as `positionKey` in `lib/services/master_games/position_key.dart`,
   or a real Zobrist over `Board`'s ten bitboards + castles + turn + legal-ep
   file) for `fenToNodes`, `buildFenIndex`, `EvalCache`, `MaiaCache`,
   `LiveExplorerService`. Pin the tables if the key ever hits disk.

---

## A. Build pipeline (wall-clock of a generation run)

How a build proceeds today: `TreeBuildService.build` → `pool.prepareForTreeBuild`
→ `_buildBfsLoop` pops one node from `FrontierQueue` (indexed max-heap on
`searchPriority`, or FIFO) and **awaits `_processBuildNode` to completion**.
Per node: `ensureEval` via `resolveEvalChain` (FenMap canonical → EvalCache
L1/L2 → cdbdirect FFI → local sqlite → ChessDB HTTP → Stockfish), prune,
transposition bookkeeping, then `expandOurMove` (MultiPV + up to ~9 injected
single-PV searches + one Maia inference) or `expandOpponentMove` (master book
+ Maia). Phase 2 (ease/expectimax/selection) and Phase 3 (line extraction,
pruning) are synchronous on the UI isolate.

### A1. The whole build runs on one engine worker, one node at a time — dominant cost
- `lib/services/tree_build_service.dart:271` → `lib/services/engine/stockfish_pool.dart:103-106`
  `prepareForTreeBuild` = `ensureWorkers(1, threads)`: **one** Stockfish
  process with `resolvedEngineThreads` UCI threads, regardless of
  `EngineSettings.workers` (default `cores ~/ 2`, `engine_settings.dart:38`).
- `tree_build_service.dart:432-441`: `while (...) { node = queue.removeFirst(); await _processBuildNode(...) }`.
  Inside, the MultiPV search (`stockfish_expander.dart:26`), the Maia
  inference (`:102`, on its own ORT isolate), sqlite writes, book queries and
  SAN work run strictly in sequence. The engine idles during Maia/DB work;
  everything else idles during the search.
- Fixed-depth search scales sub-linearly with threads (lazy SMP); N
  single-thread workers each expanding a different frontier node scale
  near-linearly. The pool already has the pattern: `forEachParallel`
  (`stockfish_pool.dart:206-247`) and `computeEngineTails`
  (`engine_tail.dart:378-411`) use work-stealing lanes.
- **Fix, in steps:**
  1. Overlap what is already async: kick off `MaiaFactory.instance!.evaluate(node.fen)`
     *before* `await run.pool.discoverMoves(...)` in `StockfishExpander.expandOurMove`
     and await it after. Zero structural risk.
  2. Pop K frontier nodes into K lanes (`ensureWorkers(EngineSettings.workers)`
     with 1 thread each). `FrontierQueue`, `makeChild`, `nextNodeId` are
     single-isolate, so lanes are safe as long as tree mutation stays between
     `await`s (it does). Best-first order degrades slightly with K in flight —
     acceptable for an anytime search; if not, pop K, expand, re-heap.
  3. Prefetch Maia for opponent children at enqueue time so
     `expandOpponentMove` hits `MaiaCache._mem`.

### A2. Candidate injection = up to ~9 extra serial engine searches per our-move node
- `lib/services/generation/node_expander.dart:515-520` (one `evaluateFen` per
  legal setup SAN, awaited in a `for`), `:542-556` (master top-2), `:581-583`
  (transfer), `:592-596` (pin) → `_injectCandidateUci` `:619`
  `await run.pool.evaluateFen(childFen, config.evalDepth)`.
- Each is a full `go depth N` plus a `stop`/`isready` handshake
  (`eval_worker.dart:557-584`) on top of the MultiPV call. A 6-move setup
  string can multiply per-node engine time 2-10×.
- Fix: collect all injection UCIs first (setup ∩ legal, master, transfer, pin;
  dedupe against the MultiPV children), then one
  `go depth N searchmoves …` with `MultiPV = count` — one search sharing the
  hash — or `Future.wait` them once A1 gives the pool >1 worker.

### A3. Two FEN parses + one movegen per child created
- Every child creation calls `playUciMove(parentFen, uci)` (parse + validate
  + play + `.fen`) **and** `uciToSan(parentFen, uci)` (parse + validate +
  `makeSan` = two movegens) **and** `isWhiteToMove(childFen)` (`split`) and
  `makeChild`'s `isWhiteToMove(fen)` again (`build_run.dart:243`).
- Sites: `node_expander.dart:175-178, 466-469, 608, 641`,
  `stockfish_expander.dart:142-146`, `maia_db_expander.dart:57-75, 131-137`,
  `chessdb_book_expander.dart:269-287`, `tree_build_db_explorer.dart:259-262`,
  `engine_tail.dart:423-425` (`_sanTail`: two parses per PV ply).
  `node_expander.dart:153` calls `uciToSan` for every root candidate before
  the exclusion filter runs.
- Negligible next to a MultiPV search in Stockfish mode; **dominant CPU in
  DB-Explorer Phase 1 and the coverage sweep** (no engine, tens of thousands of
  children).
- Fix: `final pos = Chess.fromSetup(Setup.parseFen(node.fen))` once at the top
  of `expand*`; per child `final (next, san) = pos.makeSan(move)`;
  `childFen = next.fen`; `isWhite = next.turn == Side.white`.

### A4. `EvalCache` and `MaiaCache` are keyed by the full 6-field FEN — transpositions miss
- `lib/services/eval_cache.dart:150` (`INSERT INTO evals(fen, …)`) and `:213`
  (`_key = '$fen|$elo'`) use the raw FEN; `eval_chain.dart:96` passes
  `node.fen`; every `putEvalCpWhiteSoon` caller passes a raw FEN. There is no
  `canonicalize`/`normalizeFen` anywhere in `eval_cache.dart`.
- Every other key in the pipeline (`FenMap`, book `positionKey`, cdbdirect,
  sqlite provider) is 4-field. The same position by a different move order
  differs in the halfmove clock (1.Nf3 d5 2.d4 Nf6 → 1; 1.d4 Nf6 2.Nf3 d5 →
  0), so L1 *and* persistent L2 miss. `FenMap`'s canonical short-circuit
  (`eval_chain.dart:80`) only covers positions already expanded in this run;
  across resumes and rebuilds nothing does. Each miss is an awaited sqflite
  round trip plus, for Maia, a fresh inference.
- `eval_canonicalize.dart:10-11` claims both reducers feed persistent cache
  keys — not true for these two tables.
- Fix: `canonicalizeFen4` at the `EvalCache`/`MaiaCache` boundary (both `_mem`
  and SQL). Rewrite rows in an `onUpgrade`, or accept a one-time cold cache.

### A5. One autocommit SQLite write per eval, no WAL, unawaited
- `eval_cache.dart:168 → :148`: one `INSERT … ON CONFLICT` per child eval;
  `MaiaCache.put:263` one INSERT per inference. **No `PRAGMA` at all** in
  `eval_cache.dart` — contrast `master_games_db.dart:218-225` and
  `game_store.dart:177`, which set `journal_mode=WAL`, `synchronous=NORMAL`.
  Each statement is its own transaction (an fsync per child eval); a MultiPV
  node fires up to 16 at once and the unawaited futures queue on the sqflite
  worker.
- A *negative* lookup is never remembered (`:116-123` returns null without
  touching `_mem`), so `lookupDbEvalWhite` per Maia candidate
  (`maia_db_expander.dart:63`) re-queries known misses.
- Fix: WAL + NORMAL on open; buffer puts and flush every ~200 entries or 1 s in
  one `batch()`; memoize misses with a sentinel entry.

### A6. Master-book SELECT repeated per node *and* per child
- `BuildRun.bookAt` (`build_run.dart:110`) runs `SELECT … FROM book WHERE pos=?`
  (`master_games_db.dart:414`, sync FFI) on every call and materializes
  `BookMove`s. Per node: `plyCapAt→isMasterPractice` (`tree_build_service.dart:524`),
  `_addOpponentChildrenFromMasterBook` (`node_expander.dart:314`),
  `injectMasterCandidates` (`:542`), `chessdb_book_expander.dart:95/154/223`.
  Per *child*: `masterPriorityFactor` (`node_expander.dart:192, 495, 682`,
  `chessdb_book_expander.dart:290`) → `masterGamesAt` → full query just to sum
  `games`. An our-move node with 8 children issues ~10 identical selects.
- Also makes `stats.masterBookQueries` / `masterBookHits` meaningless.
- Fix: per-run `Map<int, List<BookMove>>` on `BuildRun` keyed by `positionKey`,
  with the games-sum cached; count a query only on memo miss.

### A7. Skeleton-plan getters rebuilt per node, with FEN parses per skeleton node
- `config.skeletonPlan.pinsByFen` (`skeleton_plan.dart:219`) builds a new map
  from all skeleton nodes on every call — `node_expander.dart:592` calls it
  per our-move node (the selector caches it as `late final _pins`; the
  expander does not).
- `transferFor` (`skeleton_plan.dart:227-243`) is called **twice** per
  our-move node (`node_expander.dart:581`, `:723`); per call it does
  `tryParseFen` + for every skeleton node `_placementDiff` (expands *both*
  placements to 64 chars, `:375`, including the never-changing
  `n.placement`) + `uciToSanOrNull` (full parse + movegen) for every node in
  range. A 200-node skeleton ≈ 400 placement expansions + up to 400 FEN parses
  per our-move node.
- `parseSetupMoves(config.setupMoves)` (regex split) runs per node at
  `node_expander.dart:515` and `:718`.
- Fix: precompute `expandedPlacement` on `SkeletonNode`; parse `beforeFen`
  once and test legality via `pos.legalMoves`; `late final` `pinsByFen`;
  memoize `transferFor` per FEN in the expander; cache the setup set.

### A8. Coverage sweep and DB-Explorer enrichment are serial
- `tree_build_service.dart:658-714`: one `expandOurMove(rep, coverageOnly: true)`
  (a MultiPV search) per dangling group, awaited in sequence. A recorded run
  swept 152 minutes for 4,590 holes.
- `tree_build_db_explorer.dart:348-352`: `await ensureEval(dbOnly: true)` per
  node in a `for` — `ChessDbApiProvider` has a concurrency semaphore
  (`chessdb_api_provider.dart:374`) that never sees more than one request.
  `:380-385`: the Stockfish phase is one FEN group at a time although
  `forEachParallel` exists.
- Fix: both are independent per position — bounded lanes
  (`chessDbApiConcurrency` for the external phase, `pool.forEachParallel` for
  the engine phase), on top of A1.

### A9. Verifier fan-out vs. the 60 s acquire timeout (likely silent failure)
- `repertoire_verifier.dart:282` → `stockfish_pool.dart:192-195`
  `Future.wait(fens.map(evaluateFen))` queues every FEN as a waiter at once;
  `acquire` (`:144-163`) times out at 60 s. With the one-worker build pool and
  depth-20 evals of a few seconds each, any spine beyond ~15-20 positions makes
  tail waiters throw `TimeoutException`; `_verifyPhase` catches everything and
  logs "Verification pass failed", keeping the shallow evals. (Arithmetic from
  the code as written; not executed.)
- Fix: implement `evaluateMany` on top of `forEachParallel` (one acquire per
  lane), or pass a large timeout for batch work.

### A10. Progress emission walks the whole tree
- `tree_build_progress.dart:83` `depthHistogram(tree.root)` is O(n) on every
  emitted event; throttled to 250 ms (`:22`), but `emitNodeProgress` is called
  per created child, so it fires at the cap. On a 30k-node tree that is
  ~120k node visits/s of UI-isolate CPU for the whole build, for a per-ply
  histogram.
- Fix: maintain `depthTotals`/`depthExplored` incrementally in
  `BuildRun.makeChild` and wherever `explored = true` is set. (`:158`
  `removeAt(0)` on a `List` — use a `Queue`.)

### A11. `serializeTree` on the UI isolate for pause/cancel; `Isolate.run` deep-copies the tree
- `generation_session_controller.dart:1337` runs `serializeTree(tree)`
  synchronously from `pauseBuild` (`:1361`) and `cancelBuild` (`:1396`);
  `snapshot_exporter.dart:115` likewise. `JsonEncoder.withIndent('  ')` over
  a 30k-node nested map is hundreds of ms to seconds — the UI freezes exactly
  when the user clicks pause.
- The final save (`:1121`) and failure dump (`:1303`) use
  `Isolate.run(() => serializeTree(tree))`, which deep-copies the whole
  `BuildTreeNode` graph (parent back-pointers included) into the isolate —
  comparable cost, still on the UI isolate, *before* the isolate starts.
- Fix: no indent for partial/debug files; build the node map iteratively and
  hand the *map* to the isolate for `jsonEncode`; for pause, encode via a
  `ChunkedConversionSink` across microtasks. Longer term a columnar
  representation (typed-data arrays + parent index) makes snapshots a memcpy.

### A12. `GeneratedRepertoire.fromTree` = four full-tree walks + a redundant trap extraction
- `generated_repertoire.dart:360-370`: `FenMap.populate`,
  `EvalTreeSnapshotAdapter` (snapshot + `List.unmodifiable` per node),
  `EvalTreeLineMetricsCache`, `TrapExtractor.extract` — which re-runs
  `analyzeTrapScore` on every opponent node that `computeTrapScores`
  (`eca_calculator.dart:524`) already scored in Phase 2.
  `generation_session_controller.dart:1153` may run `TrapExtractor.extract` a
  third time. ~100-500 ms on the UI isolate per publish.
- Fix: derive traps from the stored `node.trapScore`; move the snapshot walks
  into the same isolate as A11, or at least dedupe with Phase 2.

### A13. `LineExtractor` copies path lists at every DFS level, rebuilds all prefixes per round
- `line_extractor.dart:356, 366, 582-590`: `[...movesSan, x]`,
  `[...movesUci, x]`, `[...moveAnnotations, x]`, `[...choices, x]` per
  recursion step → O(depth²) allocations per line, in both traversals, up to 5
  repair rounds (`:275-291`). `_playedPrefixes` (`:316`) builds every prefix
  string of every line each round, again in `withdrawDanglingTranspositions`
  (`:418`); `_reassignUnreachableOwners:308` joins per merge.
- Fix: push/pop shared mutable lists and copy only in `_emitLine`; every
  played prefix corresponds to a tree node, so keep a `Set<int>` of emitted
  node ids instead of joined strings.

### A14. Structure-veto lookahead reparses FENs with no memo
- `repertoire_selector.dart:222` `_structureLookahead` calls
  `tryParseFen(node.fen)` at every leaf of a 4-ply lookahead (`:234/:247`),
  for every candidate child of every our-move node, and again on each
  verifier re-selection pass. Only when vetoes are configured; then
  O(nodes × branching⁴) parses.
- Fix: one post-order pass computing `structureScore` per node before selection.

### A15. Minor (low)
- `tree_my_ease.dart:82-85`: per child, `where().toList()..sort()` over the
  siblings to find the top two — O(k² log k) per node.
- `chessdb_api_provider.dart:243/299` `unawaited(flushQuota())` writes two
  SharedPreferences keys per successful API call.
- `node_expander.dart:8-10` and `tree_build_service.dart:5` still describe
  Lichess explorer as an opponent source; nothing in the pipeline touches it.
  Doc drift.

---

## B. Repertoire load / save / edit (whole-file work per action)

The data model: a repertoire is a folder of chapter `.pgn` files
(`repertoire_creation.dart:38-66`, `chapter_store.dart:478-486`). There are
**four** game splitters (`splitPgnIntoGames` `pgn_parsing_service.dart:53-103`;
`_splitPgnDocumentPreservingPreamble` `repertoire_service.dart:441-484`;
`parseMultiGamePgn` `pgn_collection_helpers.dart:594-620`; `splitPgnGames`
`pgn_freq_parser.dart:455-491`) and **five** tree/line types (dartchess
`PgnGame`, `OpeningTree`, `MoveTree`, `RepertoireLine`, `BuildTreeNode`).
One chapter load does: PGN → split → per-game re-serialization via
`buildGame` → `PgnGame.parsePgn` (isolate 1) → `OpeningTree` → JSON maps →
`OpeningTree` again; **in parallel** PGN → split again → `PgnGame.parsePgn`
again (isolate 2) → `RepertoireLine`. Selecting a line: `RepertoireLine.fullPgn`
→ `PgnGame.parsePgn` a third time → `MoveTree` (`repertoire_controller.dart:318`).
Saving: `MoveTree` → movetext → whole-file re-split + re-parse of every game
to find the line by id → whole-file write.

### B1. Every chapter load parses every game twice, in two isolates, after re-serializing each game
- `lib/core/repertoire_loader.dart:116-131, 163-196`: `_buildOpeningTree`
  splits, runs `extractHeaders` (regex) per chunk, `split('\n')`s each chunk
  again, rebuilds a new PGN string per game with `buildGame`, ships the list
  to `Isolate.run` where `OpeningTreeBuilder._buildTreeSync` parses + replays
  every game. Then `_parseLines` (`:140`) sends the **entire original text** to
  a second `compute`, which splits and parses every game again
  (`repertoire_service.dart:89-108`).
- Hot: per load, per chapter switch, and per **undo**
  (`repertoire_controller.dart:824-861` calls `_loader.build` again).
- Side effect seen while reading: `buildGame` drops `[FEN]`/`[SetUp]` and
  `_processGame` never passes a start position, so the tree walk of a
  custom-start chapter breaks at ply 1. Correctness, not perf — worth a test.
- Fix: one isolate, one split, one parse per game, producing both the tree and
  the lines; pass the original chunk to the tree builder.

### B2. Every single-line edit re-parses the whole file with dartchess to find one game
- `repertoire_service.dart:264-283` (`lineIdsForGames`: `PgnGame.parsePgn`
  **every game**, full move-tree build, just to compute ids), `:509-515`,
  `:530-552` (`_editLineInFile`: read → split → ids → mutate one string →
  rewrite whole file). Rename, `updateLineContent` (editor autosave via
  `repertoire_controller.dart:590`), delete, review-header writes all go
  through it. `appendMoveAtPath` (`:911-958`) does the same parse-all scan for
  a browse-add click (`repertoire_writer.dart:63-108`).
- Hot: per browse click, per autosave, per review rating.
- Fix: the index-addressed path already exists (`_editGameAt`,
  `RepertoireLine.gameIndex`) — route id-based edits through it; derive ids
  with `tokenizeMovetext`+`tokenToSan` (`pgn_freq_parser.dart:494-569`) at a
  fraction of `parsePgn`'s cost (add a test proving equality with the
  dartchess mainline, since ids are persisted); cache `lineIdsForGames` per
  file mtime.

### B3. Build-by-playing commit: per uncommitted ply, parse every game, write, rebuild everything
- `build_by_playing_controller.dart:516-528` loops `_uncommittedSuffix`, each
  ply → `writer.addMoveAtPosition` (`repertoire_writer.dart:465-511`) →
  `appendMoveAtPath` (B2: parse N games, rewrite) → `appendMoveToExistingLine`
  (`repertoire_controller.dart:708-746`: replay full path into the opening
  tree, O(lines) `findLineIndexForPrefix`, `notifyListeners`) → full screen
  rebuild (C1) → outline flatten (C2) → `_syncOutline` sees a new
  `repertoirePgn` → `outline.refresh()` re-stats every chapter.
  `acceptSuggestion` (`repertoire_writer.dart:393-425`) has the same shape and
  additionally `_fenAtPath` re-parses + replays the prefix per move.
- Hot: per commit; K plies × (parse N games + write + 2 full rebuilds +
  outline refresh). A 300-game chapter with K≈6 is a visible freeze.
- Fix: one `appendMovesAtPath(path, [plies])` that reads/parses/writes once;
  parse off-isolate; one `notifyListeners` per commit; debounce
  `_outline.refresh()`.

### B4. Opening-tree build: `pos.fen` + `indexNode` per ply per game, not per node creation
- `pgn_tree_core.dart:268-270, 317-319` + `opening_tree.dart:153-163, 478-482`:
  for every ply of every game, `currentPos.fen` (full serialization) is
  computed as the `getOrCreateChild` argument even when the child exists, then
  `indexNode` does `normalizeFen` + a linear `List.contains`. 5k games × 30
  plies = 150k redundant FEN builds + scans (in an isolate, but it is the
  load-time critical path).
- Also per game: `isRepertoirePlayer` builds `RegExp(r'[^a-z]+')` per call
  (`pgn_tree_core.dart:42`, 2× per game); `splitPlayerNames` per game (`:54`).
- Fix: `children[san] ?? create(...)`; compute `fen` and call `indexNode` only
  on creation; hoist the regex.

### B5. Viewer annotation/edit rewrites the whole collection file and the `.fenidx` per action
- `pgn_viewer_controller_metadata.dart:444-492`, `viewer_game_model.dart:476-489`,
  `pgn_viewer_widget_line_actions.dart:200-208`: each added move / NAG /
  comment → `buildAnnotatedMovetext` rebuilds a full dartchess tree and
  `makePgn()`s the whole game → (300 ms debounce) `doPersistMetadata` copies
  **every game's pgnText** into a `compute` isolate (4 regexes per game),
  rewrites the **entire file**, then `_fenIndex.persist` re-serializes and
  rewrites the whole FEN index. For a 1000-game library cache: a multi-MB
  isolate copy + two file writes per annotation.
- Fix: patch only the edited game — `GamesLibraryService.patchGameMovetexts`
  (`games_library_service.dart:437-471`) already does exactly this; mark the
  FEN index dirty and persist once on close/file switch.

### B6. Frequency scanner loads a multi-GB PGN as one `String` and `split('\n')`s it
- `pgn_freq_parser.dart:201-206, 469`: `readAsBytesSync` → decode to a Dart
  `String` (2 bytes/char) → `split('\n')` (a `List` of every line) →
  `splitPgnGames` builds every game's movetext. Peak memory ≈ 3-4× file size;
  no streaming.
- Also `:390-394`: once `plyTracked >= maxPly` but `retaining` is still true
  (up to 120 plies), `fenKey = canonicalizeFen4(position.fen)` is computed and
  discarded (`recordReach` and `visitedKeys.add` are gated on `counting`).
  With a shallow `maxPly` that is most of the replayed plies. Per-game
  `RegExp(r'(\d{4})')` at `:633` and `pgn_freq_map.dart:215`.
- Fix: the splitter is already a line state machine — feed it from
  `openRead().transform(utf8.decoder).transform(LineSplitter())` in the
  isolate; guard the fen computation with `if (counting)`; hoist regexes.

### B7. Character-level lexers allocate a one-char `String` per character
- `eval_canonicalize.dart:12-20` (`fen[i] == ' '`),
  `pgn_freq_parser.dart:500-546` (`movetext[i]`, `_isTokenBoundary(String ch)`).
  `canonicalizeFen4` sits behind every `normalizeFen` (131 call sites) and
  runs per ply in the freq scan and in `positionKey` for the master import
  (`master_games_importer.dart:708`) and game store (`game_store.dart:346`);
  `tokenizeMovetext` runs over the whole text of a 2M-game TWIC corpus.
- Fix: `codeUnitAt` + integer comparisons (the code already does this for
  `_isDigit`).

### B8. `OpeningTree` isolate transfer ships every FEN twice as nested maps
- `opening_tree.dart:648-736`: each node becomes a `Map<String,dynamic>` with
  its FEN, then `fenToNodes` is serialized again with FEN keys, then the
  SendPort copies it all, then it is rebuilt. `fenToNodes` is fully derivable
  from the nodes.
- Fix: drop `fenToNodes` from the transfer and rebuild on receipt; longer term
  flat typed lists (parent ids `Int32List`, stats `Int32List`, FENs in one
  joined string) instead of a map per node.

### B9. Whole-file `split('\n')` repeated 2-4 times per load
- `pgn_parsing_service.dart:55`, `:287` (`extractRepertoireColor` splits the
  whole file to read 20 lines), `repertoire_loader.dart:211`
  (`parseRepertoireHeaders`, no early exit), `repertoire_service.dart:445`,
  `pgn_collection_helpers.dart:596-607` (regex-lookbehind split, then every
  chunk re-split just for the comment-only check). `countPgnGames` (`:122`)
  still uses the slow path from `pgn_sources_panel.dart:71` and
  `pgn_import_dialog.dart:96,171`, while `countPgnGamesFast` (`:136-161`)
  exists.
- Fix: `indexOf('\n')` scanning; early-return header readers.

### B10. Small hoists and dead work in per-game loops
- `RepertoireLine.variations` (`repertoire_service.dart:161-162, 406-430`) is
  computed for every game (walks every RAV, joins SAN strings) and has no
  consumer outside model/service/authoring. Delete it.
- Per game at `:121-131`: `mainline()` iterated twice; `RegExp(r'CumProb…')`
  constructed per game and run over the whole game text (`:358`);
  `parseImportanceComment` runs two more regexes over the whole text (`:364`);
  `Map.from(game.headers)` (`:186`). Search only the header block/comments.
- `RegExp` constructed inside per-edit/per-game functions:
  `repertoire_service.dart:561,714,844,992`, `game_store.dart:561,564`.
- `repertoire_authoring.dart:56` `extractLastGamePgn` re-splits the entire
  updated file after a browse add just to take the last game
  (`repertoire_controller.dart:734`).
- Slice slow path (`pgn_parsing_service.dart:567-627`): with both a position
  and a sequence filter, each game is `_parsePgnForReplay`'d twice;
  `MatchMode.values.firstWhere` per filter per game; query lower-cased per game.

---

## C. UI navigation (per keypress / per rebuild)

How the repertoire screen gets its data: `RepertoireScreen`
(`lib/screens/repertoire_screen.dart:436-481`) owns one `RepertoireController`
(`MoveTree` + `TreePath _cursor`). Every `notifyListeners()` (each `jump`,
`playMove`, comment/NAG edit, autosave, load) → `_onRepertoireChanged`
(`:550-588`) → `setState` on the **whole screen**; the outline panel rebuilds
again via its own `ListenableBuilder`. The cursor setter (`:97-100`) re-syncs
the `OpeningTree` on every move.

**What lichess-mobile does:** mutable model tree, immutable `ViewRoot`
snapshot rebuilt *only when the node list changes* (`shouldRecomputeRootView:
isNewNode`), `currentNode` exposed as a shallow copy (never `node.view`, which
deep-copies the subtree); the move-list widget debounces path changes 150 ms
and caches rendered mainline segments, rebuilding only the segment that lost
and the one that gained the current move (`_CachedRenderedSubtree`,
`containsCurrentMove`). Engine and explorer requests are debounced 250-300 ms
*before* being issued and cancelled on dispose.

### C1. Every navigation rebuilds the whole screen, and every child sees a "changed" move sequence
- `repertoire_controller.dart:108-111`: `moveHistory` / `currentMoveSequence`
  allocate a **fresh list on every read** (`sanSequenceAt` →
  `nodeListAt(...).map().toList()`, `move_tree.dart:236-256`). It is passed at
  `repertoire_screen_tabs.dart:111,137,279,414,442`,
  `repertoire_screen.dart:280,314`, `repertoire_analysis_dock.dart:242`. Any
  child comparing it by identity in `didUpdateWidget` does real work on
  *every* screen rebuild, not just cursor moves:
  - `opening_tree_widget.dart:100-106` → `_filterLines()` (`:114-151`): full
    `where` + `sort` over all `repertoireLines`, plus `extractEventTitle(line.fullPgn)`
    (splits the whole PGN, `pgn_utils.dart:565-579`) per line when searching,
    then `setState`. `RepertoireLinesBrowser` already fixed this exact bug with
    `listEquals` (`repertoire_lines_browser.dart:130-137`).
  - `browse_panel.dart:94-100` → `_loadCandidates()` on every parent rebuild →
    `CandidateService.getCandidates` (explorer fetch/cache +
    `openingTree.hasMoveOnPath` per child, which `reset()`s and re-walks the
    shared tree, `opening_tree.dart:524-530`).
- Also per read: `position` (`:120`) re-parses the FEN; `recentMoveTrail`
  (`:126-142`) parses + replays (`training_board_controls.dart:67` reads it per
  build).
- This is the amplifier for C2, C4, C6, C7.
- Fix: cache `moveHistory` (unmodifiable) and `Position` in `set _path`;
  `listEquals` where identity is used; replace the screen-wide `setState` with
  per-zone `ListenableBuilder`/`Selector` (board, PGN pane, outline, side
  panel).

### C2. Outline panel flattens the whole repertoire into `ListView(children:)` on every rebuild
- `repertoire_outline_panel.dart:238-257`: `_appendFolder` builds a `_LineRow`
  for every visible line, then `ListView(children: rows)` (`:253`, not
  `.builder`). Triggered by the controller `ListenableBuilder` (`:157`), by
  every parent rebuild (C1), by each 200 ms search tick, by the at-position
  toggle.
- Per build: `_visibleCount` (`:138-143`) runs twice per chapter (`:303`,
  `:319`); `_lineVisible` (`:131-136`) does `line.moves.join(' ').toLowerCase()`
  per line per call (~3 joins per line per build while searching);
  `_folderVisible` (`:150-153`) re-evaluates `allChapters.any(_chapterVisible)`
  at every nesting level; `chapter.sections` (`repertoire_outline.dart:487-495`)
  is O(lines × sections) via `List.contains`; `linesIn(section)` (`:497-498`)
  rescans per section (`panel :342-362`); `outline.lineCount` (`:436`) and
  `allChapters.length` (`panel :166-167`) walk the tree; `_FolderRow` calls
  `folder.lineCount` per folder (`:1128`). `_LineRow.build` (`:1274-1330`)
  calls `line.preview()` **and** `line.preview(maxPlies: 4)` per row per build,
  the second only for a drag label almost never shown.
- Hot: per navigation and per keystroke; scales with total lines (a 900-line
  course ≈ thousands of allocations + joins per arrow key).
- Fix: compute a flat `List<OutlineRow>` in the controller once per (outline
  version, expanded/open sets, search, atPosition, `listEquals(currentMoves)`);
  precompute lowercase haystacks and section grouping in `_linesOf`
  (`repertoire_outline_service.dart:133-144`); `ListView.builder(itemExtent: 30)`
  with `ValueKey('$path#$gameIndex')`; build drag feedback lazily.

### C3. `InteractivePgnEditor` rebuilds the whole movetext on every cursor move
- `interactive_pgn_editor.dart:606-616`: the cache is valid only while
  `widget.currentPath == _cachedPath`, so every `jump` discards all rows and
  re-walks the tree (`:617-768`): a `MoveChip` + `WidgetSpan` per node,
  `commentProseSpans` per comment (`:671`), `hasPuzzleStart/End` per node
  (`:649,657`), `qualityNagSuffix` per node (`:817`), then every `Text.rich`
  re-lays out. `pgn_with_analysis_pane.dart:229-234` `_selectedLineTitle()`
  runs `extractEventTitle(line.fullPgn)` per build on top.
- Fix (the lichess-mobile pattern): key the cache on a tree *version* (bump
  on mutation) and keep the span list across cursor moves; render selection
  via an `InheritedNotifier<TreePath>` / `ValueListenable` so only the
  previously- and newly-selected chips rebuild.

### C4. Opening-tree pane recomputes continuations with full legal-move + SAN generation per build
- `opening_tree_widget.dart:168-169` (`build()`): `tree.currentGroup` and
  `tree.continuations` every rebuild → `continuationsAt`
  (`opening_tree.dart:360-381`): `PositionGroup.children` regroups + sorts
  (`:295-304`; comparator re-folds `gamesPlayed` per compare), then
  `_legalSanDestinations` (`:741-773`) parses the FEN and calls
  `position.makeSan(move)` + `next.fen` + `normalizeFen` for **every legal
  move** (~30-40) — each `makeSan` being two move generations (§0). All of it
  to find one-ply transpositions that are almost never there.
  `goToEnd` (`viewer_opening_tree.dart:243`) calls it per step.
- Per row: `resolveCoverageStatus` (`coverage_annotation.dart:1036-1051`)
  scans `tooShallowLeaves`/`tooDeepLeaves`/`coveredLeaves` with
  `normalizeFen(leaf.fen)` per leaf; `_hasUnaccountedFrom` (`:1099-1119`)
  loops all `unaccountedMoves` with `node.children.keys.toSet()` and
  `node.getMovePath()` inside the loop — O(rows × unaccounted × depth) per
  build when a coverage result exists.
- Hot: every rebuild while the Tree tab is visible (per navigation, per any
  unrelated `setState` from C1, per engine tick).
- Fix: in `_legalSanDestinations`, `playUnchecked` each legal move (they come
  from `legalMoves`, so they are legal), look the dest FEN up in `fenToNodes`,
  and call `makeSan` only for hits; memoize `continuationsAt`/`currentGroup`
  per normalized FEN inside `OpeningTree` (invalidate in
  `appendLineFromFen`/`removeChild`/`indexNode`); store `gamesPlayed` as a
  field on `PositionGroup`; build `Map<normalizedFen, CoverageStatus>` once per
  `CoverageResult`.

### C5. Board re-parses the FEN and remounts the whole board on every move
- `repertoire_board_pane.dart:41` `positionFromFen(displayFen)` →
  `Chess.fromSetup(Setup.parseFen)` (`repertoire_screen_session.dart:779-786`)
  per build; `ChessBoardWidget(key: ValueKey(displayFen))` (`:59`) means a
  new cursor position disposes and recreates the board `State`,
  `LayoutBuilder`, painters and every `PieceImage`. `buildAuditBoardAnnotations`
  (`repertoire_screen_layout.dart:231-234`) is recomputed per build.
- Fix: cache `Position` in the controller (C1); drop the `ValueKey(fen)` —
  `ChessBoardWidget.didUpdateWidget` already resets drag state on position
  change (`chess_board_widget.dart:430-436`).

### C6. Cursor sync replays the whole path with dartchess although every node already has its FEN
- `repertoire_controller.dart:97-100` → `_syncOpeningTree` →
  `OpeningTree.syncToMoveHistory` (`opening_tree.dart:586-637`): `reset()`,
  parse root FEN, `playSanOrNullMove` + `position.fen` + `normalizeFen` per
  ply — O(depth) SAN parsing per `jump`, while `MoveTree` already stores the
  FEN after each move. `makeMove` → `_snapToPlayedFen` (`:412-426`) parses a
  FEN too; `doesMoveTranspose` (`:511-521`) likewise.
- Hot: per navigation (a held arrow key = one replay per ply per repeat).
- Fix: `syncToFens(sans, fens)` fed from `nodeListAt`; or incremental
  `goForward` → `makeMove(san)`, `goBack` → pop the walked path; keep the
  cursor `Position` alongside `_offBookFen`.

### C7. PGN viewer replays the mainline from the start on every step — twice
- `viewer_game_model.dart:86-102` `goToMainLineMove` replays `moveIndex`
  plies (`parseSan` + `play` each); `goToAnalysisNode` replays branch + path;
  `mainlineIndexOfFen` (`:106-117`) replays the whole game normalizing each
  FEN. `_recentMoveSquares` (`pgn_viewer_widget_navigation.dart:357-390`)
  replays from the start again and is read *during build* at
  `pgn_viewer_screen_panes.dart:37,82`. Meanwhile `_buildPrefixPositions`
  (`pgn_movetext_prose_scan.dart:95-118`) already caches `List<Position>` per
  game via an `Expando` — the same data.
- Fix: keep the prefix `List<Position>` in `ViewerGameModel` (append in
  `addMove`'s `extendedMainline` branch; invalidate on mainline edit) and index
  into it for navigation, `mainlineIndexOfFen`, and `recentMoveSquares`.

### C8. Eval-tree layout: hundreds of `TextPainter.layout()` calls per controller notify
- `eval_tree_tab.dart:166` — `EvalTreeLayoutEngine.buildFrame` inside
  `AnimatedBuilder(animation: _controller)` runs on every select/zoom/setting
  change: `_estimateNodeSize` (`eval_tree_layout_engine.dart:400-431`) does up
  to two `TextPainter(...).layout()` per visible node (cap 400 → up to 800
  layouts); `frame.nodes` (`:75-80`) copies and sorts the map on every access
  (`eval_tree_viewport.dart:839`); `EvalTreeViewport.didUpdateWidget`
  (`:754-772`) builds two sets and a difference.
- Fix: memoize node sizes per `(nodeId, metricDisplayMode)` on the snapshot;
  memoize the frame per `(selectedNodeId, visiblePly, spine, maxDisplayNodes,
  mode)`; make `nodes` a lazily-sorted field.

### C9. Live explorer cache key is not normalized; the spinner flashes on every ply
- `live_explorer_service.dart:113-115` keys by the raw FEN (clocks included)
  while `ExplorerCacheService._key` (`explorer_cache_service.dart:82`) uses
  `normalizeFen` — the two caches never share, and transpositions /
  different counters miss. `request()` (`:119-142`) sets `state = loading(fen)`
  synchronously *before* the 250 ms debounce, and `_buildBody`
  (`opening_explorer_panel.dart:929-939`) swaps the list for a
  `CircularProgressIndicator`, so scrubbing tears down and rebuilds the
  explorer `ListView` on every ply, even for positions immediately superseded.
- lila keeps the previous rows (stale-while-loading), debounces 250 ms
  *before* issuing, aborts the in-flight fetch, stops after N consecutive
  empty results (`movesAway`), and lichess-mobile stops at ply 50.
- Fix: normalize the key; back the panel with `ExplorerCacheService`; keep
  previous rows visible (dimmed) until the debounced fetch lands; add a ply /
  consecutive-empty cutoff.

### C10. Lines browser index/metrics rebuilt synchronously on the UI isolate on every lines change
- `repertoire_lines_browser.dart:445-483`: `buildLineDisplayIndex`
  (`lines_filter_helpers.dart:43-57`: `extractEventTitle(line.fullPgn)` splits
  every full PGN, two joins per line — O(total PGN bytes)) and
  `computeLineMetricsMap` (`line_metrics_helpers.dart:33-88`; `walkTreeForLine`
  `:90-99` allocates a `where().toList()` per ply, plus a fresh
  `TrapIndexService(traps)`) run in `initState`/`didUpdateWidget` whenever
  `lines`, `tree`, `traps` or `coherenceResult` identity changes (every
  `appendNewLine`, autosave, reload). Sorting lower-cases `a.name` per
  comparison (`lines_filter_helpers.dart:158-159`).
- Fix: compute the display index and lowercase names in the parse isolate
  (they depend only on `RepertoireLine`); store metrics on the controller keyed
  by line id.

### C11. Background progress rebuilds the whole screen and the bottom pane
- `audit_session_controller.dart:224-241` `onLiveFinding`/`onProgress` notify
  unthrottled (every 5 nodes, `repertoire_audit_service.dart:151`, and per
  finding) → `_onAuditChanged` `setState` (`repertoire_screen_session.dart:638-641`);
  `CoverageController.calculate` notifies per progress callback
  (`coverage_controller.dart:103-107`). `_buildBottomPane`
  (`repertoire_screen_tabs.dart:301-312`) is a `ListenableBuilder` on
  `JobManager`, which notifies on every `updateProgress`
  (`repertoire_job.dart:100-102`, including generation's 100 ms ticks) and
  rebuilds `AuditFindingsPanel` + `JobsTabContent` each time. Generation itself
  is throttled correctly (`generation_progress.dart:25,107-121` + 250 ms on the
  screen).
- Each tick pays C1, C2, C3, C5.
- Fix: throttle audit/coverage like generation; scope the bottom pane's
  listener to the jobs tab content.

### C12. Trainer `ChapterScope` re-filters all lines on every access
- `chapter_scope.dart:49-52` `lines` copies/filters on every read; `names`
  (`:106-114`), `hasUngroupedLines` (`:117-118`), `scopedLines` (`:121-126`)
  each re-filter. `TrainingSessionController.countsFor` (`:608-611`) and
  `remainingInRun` (`:714-716`) are O(lines) with `lineStatusOf` per line; the
  trainer screen reads `chapters` (`repertoire_training_screen.dart:135`),
  `remainingInRun` (`:746`) and filters lines (`:763`) per build, and every
  session move notifies (`:226`).
- Fix: cache the trainable-lines list and chapter names per `lines`
  assignment; store `remainingInRun` when the queue is rebuilt.

### C13. Minor
- `repertoire_outline_service.dart:73-113`: `await _buildFolder` per subdir
  and `await _linesOf` per chapter sequentially; `_linesOf` re-`fileStat`s
  (`:119`) what `listChapters` (`io_storage_service.dart:211-238`) already
  stat'ed. `Future.wait` per level.
- `plan_controller.dart:619-667`: `_fillEvals` patches up to 10 candidates,
  each `notifyListeners`, then serial engine evals notifying twice each.
  Coalesce.
- `OpeningTreeNode.moverWasWhite` → `isWhiteToMove(fen)` → `fen.split(' ')`
  per ancestor in `reachEstimate`; `PositionGroup.gamesPlayed/wins/…` are
  folds re-run per access and per sort comparison; `primaryNode` reduces per
  access. Cache on the group.

---

## D. Already right — don't chase these

- **Build tree core:** `FrontierQueue` is an indexed binary max-heap with
  in-place re-sift (`frontier_queue.dart`); `FenMap` is a `HashMap` on
  4-field FEN; `BuildTree.computeMetadata` memoizes `subtreeSize` in one
  post-order pass; `LinePruner` interns keys to ints with an upper-bound skip;
  engine tails use work-stealing lanes; `GenerationProgress` throttles
  `notifyListeners` to 100 ms; `MaiaService` single-flights inference on the
  ORT worker isolate; ChessDB API has a semaphore + exponential backoff;
  cache order is cache-before-network.
- **Engine pool:** persistent workers, no `ucinewgame` between positions (hash
  reuse across the tree is what you want), 128 MB hash per worker,
  `forEachParallel` work-stealing, crash respawn, `stop`+`isready` drains
  stale `bestmove`.
- **Game DBs:** `GameStore.importChunks` (`game_store.dart:269-370`) and the
  master importer (`master_games_importer.dart:558-756`): prepared statements,
  one `BEGIN IMMEDIATE` per import, hashed `positionKey`, `WITHOUT ROWID` book
  table, WAL + import-tuned pragmas, whole-issue parse in an isolate.
- **Parsing off the UI isolate:** `RepertoireLoader._parseLines` (`compute`),
  `OpeningTreeBuilder.buildTree` (`Isolate.run`), `parseRepertoireFile`,
  study open/import, eval-tree deserialize, FP-Growth coherence mining,
  `pgn_fen_index`, `pgn_freq_cache` (single `BytesBuilder`, one write,
  manifest covering every parse setting).
- **UI:** `PgnMovetextView` prefix positions cached per game via `Expando`;
  prose-SAN legality memoized; `RepertoireLinesBrowser` compares
  `currentMoveSequence` by content; `LinesListPanel`, `CompactTreeOutline`
  (`itemExtent`), explorer and browse panels use `ListView.builder`;
  `HoverableMoveChips` renders one `Text.rich` per row; `uciToSanCached` /
  `uciPvToSanCached` exist for the engine pane; `LiveExplorerService`
  coalesces stale responses by sequence number; `ViewerOpeningTree
  .gamesAtTreePosition` has an LRU; `RepertoireOutlineService._lineCache` is
  mtime-keyed; `MoveTree.nodeAt`/`fenAt` are O(depth) on cached FENs;
  `toPgnMoveText` only on copy/save; study autosave behind a 2 s debounce.

---

## E. Recommended sequence (value ÷ effort, highest first)

Measure first: `test/benchmark/fast_vs_pure_benchmark.dart` already runs the
real pipeline end-to-end under `flutter test` with a fresh cache; add a
`Stopwatch` around Phase 1 / Phase 2 / Phase 3 and record `stats.json` before
and after each step below. For the UI, Flutter DevTools' performance overlay
on the repertoire screen while holding →.

1. **One-liners in hot loops** (an afternoon, no risk): A4 canonicalize
   `EvalCache`/`MaiaCache` keys; A5 WAL + NORMAL + batched writes + negative
   cache; B4 create-only `fen`/`indexNode`; B6 `if (counting)` guard; B7
   `codeUnitAt`; B10 hoist regexes, delete `variations`; C1 `listEquals` in
   `opening_tree_widget.dart` / `browse_panel.dart`; C9 normalize the live
   explorer key.
2. **Controller caches** (a day): C1 cache `moveHistory` + `Position` in
   `set _path`; C6 `syncToFens`; C4 cheap `_legalSanDestinations` + memoized
   `continuationsAt`; C7 prefix positions in `ViewerGameModel`; C5 drop the
   board `ValueKey(fen)`; A6 book memo on `BuildRun`; A7 skeleton memos; A10
   incremental depth histogram.
3. **Engine throughput** (two days, needs a benchmark run): A1 steps 1-3;
   A2 `searchmoves`; A8 lanes for sweep + DB-explorer; A9 `evaluateMany` on
   `forEachParallel`. This is the only item that changes build wall-clock by
   an integer factor.
4. **Per-edit whole-file work** (two to three days): B2 index-addressed
   edits + cheap id derivation; B3 `appendMovesAtPath`; B1 single parse per
   load; B5 patch-one-game for the viewer.
5. **Rebuild scoping** (two days, UI): C2 flat outline rows +
   `ListView.builder`; C3 version-keyed editor cache + selection notifier;
   C11 throttle audit/coverage and scope the bottom pane; C8 eval-tree memos.
6. **Structural** (when the above is done): §0 step 2 — lazily-populated
   `Position` on nodes; §0 step 3 — int position keys; A11/A12/B8 columnar
   tree snapshot for isolate transfer and serialization; A13 push/pop in the
   extractor.

Items 1-2 are pure wins with existing tests as the safety net. Item 3 changes
expansion order under best-first; compare `stats.json` move-choice agreement
with the harness's `MODE=compare` before trusting it.

---

## Applied — 2026-08-28 (same day, uncommitted at time of writing)

Everything above is now implemented, verified by `dart format` (clean),
`flutter analyze lib test` (0 errors / 0 warnings) and `flutter test`
(**3084 passed**, up from 2952 — every behavioural change carries a test).
Status per finding, with the load-bearing file for each:

**§0 positions-as-strings.** `MoveNode.position` / `MoveTree.positionAt` /
`MoveTree.startingPosition` (lazy, parsed once); `BuildRun.positionOf` +
`BuildRun.childMove` (bounded memo, one `makeSan` per child);
`chess_utils.playUciFrom` / `uciToSanFrom` / `moveToStandardUci`;
`OpeningTree` keeps a small LRU of legal destinations per FEN.  Int position
keys (step 3) were **not** adopted: every persistent key is now the 4-field
FEN, which is what the on-disk caches already use.

**A.** A1 `lanes.dart` + `_buildBfsLoop` runs `run.expansionLanes` lanes
over a shared `FrontierQueue` with an in-flight set and a `LaneGate`;
`prepareForTreeBuild` provisions `EngineSettings.workers` single-thread
workers under the thread budget (`laneCountFor` / `threadsPerLane`); Maia
overlaps the MultiPV search and is prefetched for opponent children.  A2 one
`searchmoves` MultiPV per node (`NodeExpander.injectCandidates`,
`EvalWorker.runDiscovery(searchMoves:)`).  A3 as above.  A4/A5
`eval_cache.dart` rewritten: canonical keys, schema v3 migration, WAL +
NORMAL, batched `_WriteQueue`, negative cache, `flush()`.  A6 `BuildRun`
book memo.  A7 `SkeletonNode.expandedPlacement`, `late final` pins,
per-FEN transfer memo, cached setup set.  A8 lanes for the coverage sweep
and both DB-explorer phases.  A9 `evaluateMany` on `forEachParallel`.  A10
incremental depth histograms in `BuildRun`.  A11 `serializeTreeJson` (explicit
stack) + `serializeTreeInIsolate`; compact encoding for partial/debug saves.
A12 `TrapExtractor` skips nodes Phase 2 already scored under the bar.  A13
push/pop path lists in `LineExtractor`.  A14 memoised structure lookahead.
A15 done.

**B.** B1 one isolate, one split, one parse per game
(`repertoire_loader.dart:_loadGamesInIsolate`); custom-start chapters keep
their `[FEN]`.  B2 ids from the cheap mainline lexer, mtime-keyed cache,
index-addressed edits.  B3 `RepertoireService.appendMovesAtPath` +
`RepertoireWriter.addMovesAtPosition`; build-by-playing commits and
`acceptSuggestion` write once.  B4 `OpeningTree.advance`.  B5 viewer edits
patch one game and persist the FEN index lazily.  B6 streaming scanner
(`_forEachGame`, `PgnGameSplitter`, UTF-8 validation pass with Latin-1
fallback).  B7 `codeUnitAt` everywhere hot.  B8 `fenToNodes` rebuilt on
receipt.  B9 `indexOf`-scanning splitters; fast `countPgnGames`.  B10
`RepertoireLine.variations` gone, regexes hoisted, single mainline pass.

**C.** C1 `RepertoireController` caches move history and `Position` per
cursor; `structureVersion` separates edits from cursor moves and the screen
rebuilds wholesale only for the former.  C2 `OutlineRowBuilder` /
`RepertoireOutlineController.rows` + `ListView.builder`.  C3 editor cache
keyed on `MoveTree.version`; `_SelectionAwareChip` repaints exactly the two
chips whose selection flipped.  C4 continuations memoised per cursor FEN;
coverage status index per result.  C5 no per-FEN board key.  C6
`syncToFens`.  C7 `MainlinePositions`.  C8 `EvalTreeNodeSizeCache`.  C9
normalised explorer key shared with the disk cache, stale-while-loading,
`maxPly` + `emptyStreakLimit` cutoffs.  C10 `LineDisplayIndex`.  C11
`NotifyThrottle` for audit/coverage; bottom pane scoped.  C12/C13 done.

**Deliberately left.** `upsertMetadataComment` and the header-merge helpers
in `repertoire_service.dart` still `split('\n')` — they run once per edit on
one game.  The export-time probes in `services/generation/course/` still use
the FEN-taking helpers — one parse per exported line, not per node.  The
`fast_vs_pure` overnight harness was not re-run (needs Stockfish + Maia on
the machine); the lane count is `EngineSettings.workers`, so a build with
`workers = 1` behaves exactly as before.
