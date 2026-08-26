part of 'node_expander.dart';

// ── ChessDB mainline book expansion ──────────────────────────────────────

/// One move to play, and where the answer came from.
class _BookChoice {
  final DbMove move;
  final DbMoveSource source;

  const _BookChoice(this.move, this.source);
}

/// `BuildMode.chessDbBook`: our move is whatever ChessDB ranks best, their
/// replies are master practice, and past master practice the line continues
/// as a single mainline until ChessDB runs out.
///
/// The mode is deliberately opinion-free.  Nothing here weighs how hard a
/// move is to play, how likely a human is to find the refutation, or how the
/// position scores in practice — the tree has exactly one child at every one
/// of our nodes, so there is nothing for a valuation to choose between and
/// Phase 2 has no work to do.  What breadth exists is entirely the opponent's
/// side, and it comes from master games rather than from a model of anyone.
///
/// A line ends where ChessDB's knowledge ends.  That is the default and it
/// is the honest one: the mode promises a database's book, and a move the
/// database did not supply is not part of it.  [TreeBuildConfig.
/// bookEngineFallback] puts the engine underneath as a floor for callers who
/// would rather have the line finished than have it stop — the run summary
/// then reports how many moves came from the engine rather than from the
/// database, because a book the engine mostly wrote is a different artifact
/// and the PGN cannot tell you which one you have.
class ChessDbBookExpander extends NodeExpander {
  ChessDbBookExpander(super.run);

  @override
  Future<void> expandOurMove(
    BuildTreeNode node,
    FrontierQueue queue, {
    bool coverageOnly = false,
  }) async {
    final choice = await _bookMove(node);
    if (choice == null) {
      run.stats.bookDeadEnds++;
      return;
    }

    final child = _addBookChild(node, choice, probability: 1.0);
    if (child == null) return;
    _attachBookStats(node, child);

    // A pinned move is the user's own decision and outranks every scorer in
    // the app, this one included — but the selector can only honour a pin
    // whose child exists, so it is added here even though the database
    // preferred something else.
    await injectPinnedCandidate(node);

    final incumbent = assignOurMovePriorities(node);

    // Already decided by the eval window: the move is recorded, the subtree
    // is not. Same contract as the other expanders — this node is our turn,
    // so it gets an answer whatever the position is worth.
    if (evalWindowPrune(node, config)) return;

    if (coverageOnly) return;

    for (final c in ourChildrenToExpand(node, incumbent)) {
      if (run.isCancelled) break;
      queue.add(c);
    }
  }

  /// Opponent replies: every move masters play here, or — once the position
  /// leaves master practice — the single move ChessDB ranks best.
  ///
  /// The asymmetry is the whole design.  Branching answers a *choice*, and
  /// past master practice the opponent has stopped making choices anyone has
  /// recorded; fanning out there would spend the node budget enumerating
  /// moves nobody plays instead of following the theory that is left.  Past
  /// [TreeBuildConfig.maxPly] the book stops taking new choices for the same
  /// reason of budget rather than of principle.  Either way one move per side
  /// costs a node per ply, which is why every line may run on to
  /// [TreeBuildConfig.resolvedBookTailMaxPly] (see [BuildRun.plyCapAt]).
  @override
  Future<void> expandOpponentMove(
    BuildTreeNode node,
    FrontierQueue queue,
  ) async {
    // Past [TreeBuildConfig.maxPly] the book stops answering new opponent
    // choices and follows one line — that cap is what "branching depth"
    // means here, and it is enforced at exactly this point rather than by
    // the ply cap, which now governs the whole line's length.
    final mayBranch = node.ply < config.maxPly;

    var fromBook = false;
    if (mayBranch && run.isMasterPractice(node.fen)) {
      // No Maia prior: this book's opponent model is recorded practice, and
      // smoothing would mix in moves that are only plausible.
      fromBook = await _addOpponentChildrenFromMasterBook(
        node,
        smoothWithMaia: false,
      );
    }

    if (!fromBook) {
      final choice = await _bookMove(node);
      if (choice == null) {
        run.stats.bookDeadEnds++;
        return;
      }
      _attachBookStats(node, _addBookChild(node, choice, probability: 1.0));
    }

    if (node.children.isEmpty) return;
    for (final child in List.of(node.children)) {
      if (run.isCancelled) break;
      queue.add(child);
    }
  }

  // ── Choosing the move ───────────────────────────────────────────────────

  /// ChessDB's move for [node], or — when [TreeBuildConfig.bookEngineFallback]
  /// is on — the engine's, for a position no ChessDB source knows.
  ///
  /// Null ends the line. With the fallback off that is the normal way a line
  /// finishes: the book stops where the database's knowledge stops, which is
  /// honest and costs nothing. With it on, null means neither could name a
  /// move — a mate, a stalemate, or an engine that is not running.
  Future<_BookChoice?> _bookMove(BuildTreeNode node) async {
    final list = await run.evalResolver.lookupBookMoves(node.fen, config);
    if (list.isNotEmpty) {
      run.stats.bookDbMoveHits++;
      _recordNodeEval(node, list.bestStmCp!);
      return _BookChoice(_pickFromDb(node, list), list.source);
    }
    if (!config.bookEngineFallback) return null;
    return _engineMove(node);
  }

  /// The database's best move, with master practice breaking ties.
  ///
  /// Ties are common: ChessDB scores whole clusters of opening moves 0 or 25,
  /// and picking the first of them by list order would make the book depend
  /// on the database's internal ordering. Master games are the tie-breaker
  /// because they are the only other objective fact available — this is not
  /// a practicality weighting, and with the default
  /// [TreeBuildConfig.bookTieBreakWindowCp] of 0 it only ever separates moves
  /// the database scores exactly equal.
  DbMove _pickFromDb(BuildTreeNode node, DbMoveList list) {
    final tied = list.withinCp(config.bookTieBreakWindowCp);
    if (tied.length < 2) return list.moves.first;

    final games = <String, int>{
      for (final m in run.bookAt(node.fen)) m.uci: m.games,
    };
    if (games.isEmpty) return list.moves.first;

    var best = tied.first;
    var bestGames = games[best.uci] ?? 0;
    for (final candidate in tied.skip(1)) {
      final n = games[candidate.uci] ?? 0;
      if (n > bestGames) {
        best = candidate;
        bestGames = n;
      }
    }
    return best;
  }

  /// Engine fallback for a position no ChessDB source has seen.
  Future<_BookChoice?> _engineMove(BuildTreeNode node) async {
    if (run.pool.workerCount == 0) return null;

    final whiteToMove = isWhiteToMove(node.fen);
    final DiscoveryResult discovery;
    try {
      final sw = Stopwatch()..start();
      discovery = await run.pool.discoverMoves(
        fen: node.fen,
        depth: config.evalDepth,
        multiPv: 1,
        isWhiteToMove: whiteToMove,
      );
      run.stats.sfMultipvCalls++;
      run.stats.sfMultipvMs += sw.elapsedMilliseconds;
    } catch (e) {
      run.log('Book engine fallback failed @ ${node.fen}: $e');
      return null;
    }

    if (discovery.lines.isEmpty) return null;
    final line = discovery.lines.first;
    if (line.moveUci.isEmpty) return null;

    // DiscoveryLine scores are White-POV; the book speaks side-to-move.
    final stmCp = whiteToMove ? line.effectiveCp : -line.effectiveCp;
    run.stats.bookEngineFallbacks++;
    _recordNodeEval(node, stmCp);
    return _BookChoice(
      DbMove(uci: line.moveUci, stmCp: stmCp),
      DbMoveSource.stockfish,
    );
  }

  // ── Master practice, read past the branching cap ────────────────────────

  /// Record what master practice knows about [node]'s position and the move
  /// leading to [child], on the paths where the book is not driving the
  /// fan-out.
  ///
  /// Statistics and branching are separate questions, and tying them together
  /// was a real bug. Past [TreeBuildConfig.maxPly] the book stops *choosing*
  /// replies — and it used to stop being *read* at the same moment, so every
  /// line's game counts went blank at exactly that ply. The export then
  /// reported the branching cap as the end of theory: "Last move seen in
  /// master games (281 games)" landed on 10.Kh1 of a main-line Orthodox
  /// King's Indian, with hundreds of master games still to come after it. The
  /// book had not run out; nobody had asked it.
  ///
  /// Reading the book is a local SQLite lookup — it costs nothing like the
  /// ChessDB request that picks the move, so there is no reason to stop.
  void _attachBookStats(BuildTreeNode node, BuildTreeNode? child) {
    final book = run.bookAt(node.fen);
    if (book.isEmpty) return;

    // Fill gaps only, never overwrite. A node the fan-out already stamped
    // carries the count of the *move* that reached it; a position total is a
    // different number (it includes every move order into the position), and
    // quietly swapping one for the other would change what `[%games]` and
    // `[%score]` mean partway through a file — 5.Nf3 jumped from 8424 to
    // 13295 when this did overwrite.
    if (node.totalGames == 0) {
      var whiteWins = 0, draws = 0, blackWins = 0;
      for (final m in book) {
        whiteWins += m.whiteWins;
        draws += m.draws;
        blackWins += m.blackWins;
      }
      node.setLichessStats(whiteWins, blackWins, draws);
    }

    if (child == null || child.totalGames > 0) return;
    for (final m in book) {
      if (m.uci != child.moveUci) continue;
      child.setLichessStats(m.whiteWins, m.blackWins, m.draws);
      if (m.lastYear > 0) child.lastPlayedYear = m.lastYear;
      return;
    }
  }

  // ── Attaching the move ──────────────────────────────────────────────────

  /// Record the position's own eval, side-to-move relative, from the score of
  /// the move about to be played there.
  void _recordNodeEval(BuildTreeNode node, int stmCp) {
    if (node.hasEngineEval) return;
    node.engineEvalCp = stmCp;
    final whiteCp = isWhiteToMove(node.fen) ? stmCp : -stmCp;
    run.evalResolver.cacheEvalWhite(node.fen, whiteCp, config.evalDepth);
  }

  /// Attach [choice] to [node] as a child carrying the database's eval.
  BuildTreeNode? _addBookChild(
    BuildTreeNode node,
    _BookChoice choice, {
    required double probability,
  }) {
    final move = choice.move;
    final childFen = playUciMove(node.fen, move.uci);
    if (childFen == null) return null;

    final child = run.makeChild(
      parent: node,
      fen: childFen,
      san: move.san.isNotEmpty ? move.san : uciToSan(node.fen, move.uci),
      uci: move.uci,
    );
    if (child == null) return null;

    child.moveProbability = probability;
    child.cumulativeProbability = node.cumulativeProbability * probability;

    // [DbMove.stmCp] scores the move from the *parent's* point of view, and
    // the child is the opponent's turn — hence the flip. Mind the sign zoo
    // in README.md before touching this.
    final whiteCp = isWhiteToMove(node.fen) ? move.stmCp : -move.stmCp;
    child.engineEvalCp = isWhiteToMove(childFen) ? whiteCp : -whiteCp;
    run.evalResolver.cacheEvalWhite(childFen, whiteCp, config.evalDepth);

    final masterFactor = run.masterPriorityFactor(childFen);
    child.searchPriority =
        effectiveSearchPriority(node) * probability * masterFactor;
    child.searchPriorityDiscount = masterFactor;

    run.emitNodeProgress(child);
    return child;
  }
}
