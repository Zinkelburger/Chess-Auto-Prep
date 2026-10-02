import 'dart:async';

import 'package:dartchess/dartchess.dart' show Position, Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chess/fen.dart';
import '../chess/openings.dart';
import '../chess/generation/draft_chapter.dart';
import '../chess/generation/draft_lines.dart';
import '../chess/generation/mainline_book.dart';
import '../chess/generation/search.dart';
import '../chess/generation/search_config.dart';
import '../chess/generation/search_node.dart';
import '../chess/generation/search_result.dart';
import '../chess/generation/traps.dart';
import '../chess/generation/tree_wire_v4.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_heading.dart';
import '../chess/pgn/tree_edit.dart' show positionOf;
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/generation_trees.dart';
import '../storage/pending_writes.dart';
import '../storage/operation_id.dart';
import '../storage/pgn_document_store.dart' as store;
import 'document_session.dart';
import 'engine_jobs.dart';
import 'finds.dart';
import 'opening_names.dart';
import 'generated_draft.dart';

import 'fill_states.dart';
import 'search_opponents.dart';

/// The expectimax search from the board: the Search tab.
///
/// Owns the one run at a time, its progress and the tree it built, which
/// the Search tab reads as the board moves: a search only gets the values.
/// Reads the [DocumentSession] for the position, the line to it and the
/// side at the bottom of the board when the run starts, then works from that
/// snapshot; the user may go on reading meanwhile, and the tree so far is
/// shown as each level of it is done. Holds the machine ([EngineJobs]) for
/// the length of the run, so it never shares one with the board's engine
/// or an audit.
///
/// On a repertoire chapter the values can then be turned into lines: a
/// draft chapter written through the store as a new file beside it. The
/// chapter itself is never touched.
final class FillGaps extends ChangeNotifier {
  FillGaps({
    required DocumentSession session,
    required EngineJobs jobs,
    required store.PgnDocumentStore documents,
    required FillToolsFactory tools,
    TreeKeeper? keepTree,
    TreeLoader? loadTree,
    PendingWrites? pendingWrites,
    this.finds,
    this.openings,
    DateTime Function() clock = DateTime.now,
  }) : _session = session,
       _jobs = jobs,
       _store = documents,
       _tools = tools,
       _keepTree = keepTree,
       _loadTree = loadTree,
       _pending = pendingWrites ?? PendingWrites(),
       _clock = clock {
    _board = _boardNow;
    _session.anyChange.addListener(_boardChanged);
    _jobs.addListener(_jobsChanged);
  }

  final DocumentSession _session;
  final EngineJobs _jobs;
  final store.PgnDocumentStore _store;
  final FillToolsFactory _tools;
  final TreeKeeper? _keepTree;
  final TreeLoader? _loadTree;
  final DateTime Function() _clock;

  /// Lets the way out wait for a tree or draft still being written. A write
  /// that fails retains its destination and frozen content until a retry
  /// succeeds. An uncertain write must never become a second publication.
  final PendingWrites _pending;

  /// Where what each stopped run points out is kept: the Positions list.
  final Finds? finds;

  /// Names a draft's lines after their openings; unnamed without it.
  final OpeningNames? openings;

  FillState _state = const FillIdle();
  FillFound? _found;

  /// The same run searched for the other side, as far as it has got: what
  /// each move is worth when that side is the prepared one. The mainline
  /// book builds none.
  FillFound? _mirror;
  LinesState? _lines;
  GeneratedDraft? _draft;
  int _draftLines = 0;
  PendingObligation<DraftPublication>? _draftSave;
  final _treeResource = Object();
  String? treeSaveProblem;
  bool get canRetryTree => _pending.unfinished(_treeResource).isNotEmpty;

  Future<void> retryTree() async {
    try {
      await _pending.retry(_treeResource);
    } on Object catch (error) {
      log.w('retry search tree', error);
    }
    treeSaveProblem = !canRetryTree
        ? null
        : 'The search tree still needs saving.';
    if (!_disposed) notifyListeners();
  }

  void discardTreeSave() {
    for (final entry in _pending.unfinished(_treeResource)) {
      entry.discard();
    }
    if (!canRetryTree) treeSaveProblem = null;
    if (!_disposed) notifyListeners();
  }

  void discardDraftSave() {
    if (_draftSave?.discard() != true) return;
    _draftSave = null;
    _lines = const LinesFailed(
      'Draft save abandoned. Any file already written was kept.',
    );
    if (!_disposed) notifyListeners();
  }

  bool get canDiscardDraft => _lines is LinesFailed && _draftSave != null;

  Future<void> Function()? _release;
  Future<void>? _releasing;
  bool _active = false;
  bool _disposed = false;

  FillState get state => _state;

  /// Whether the run under way was asked to stop, either kind, or the
  /// owner has gone.
  bool get _stopping =>
      _disposed ||
      switch (_state) {
        FillRunning(:final stopping) => stopping,
        _ => false,
      };

  /// Whether what the run under way finds is to be thrown away: it was
  /// cancelled, or the owner has gone.
  bool get _discarded =>
      _disposed ||
      switch (_state) {
        FillRunning(:final cancelling) => cancelling,
        _ => false,
      };

  /// The tree of the last run, as far as it has got: filled in while the
  /// run goes and kept until the next one starts.
  FillFound? get found => _found;

  /// What became of turning the last run into lines, once asked.
  LinesState? get lines => _lines;

  bool get running => _state is FillRunning;

  final _engineDepths = <String, int>{};

  /// The engine's best line from each position it scored this session,
  /// by four-field position: what a drafted line that stops mid-fight is
  /// continued with.
  final _bestLines = <String, List<String>>{};

  int? engineDepthAt(Fen fen) => _engineDepths[fen.position];

  Completer<void>? _finished;
  // One generation for every delayed start, whether it is loading a saved
  // tree or waiting for the previous root to be saved. New intent invalidates
  // both paths, even if navigation returns to the same position (ABA).
  int _startTicket = 0;

  /// The engine as the run under way asks it: one for both of its sides.
  EngineAnswers? _answers;
  final _history = <FillFound>[];
  FillRequest? _activeRequest;
  (Object?, Fen, Side)? _board;
  (Object?, Fen, Side) get _boardNow => (
    _session.source ?? _session.analysisPage,
    _session.fen,
    _session.orientation,
  );
  Future<String?>? _following;
  bool _retargeting = false;
  bool _followEnabled = false;

  /// Retain previous roots so going back can display and resume their values.
  void _remember() {
    for (final found in [?_found, ?_mirror]) {
      _history.removeWhere(
        (old) =>
            old.tree.fen == found.tree.fen &&
            old.side == found.side &&
            old.request.compatibleWith(found.request),
      );
      _history.add(found);
      if (_history.length > 32) _history.removeAt(0);
    }
  }

  /// The board's position in the newest tree searched for [side], the
  /// bottom of the board unless another is asked for.
  SearchNode? nodeAtBoard({FillRequest? request, Side? side}) {
    final tree = _session.tree;
    if (tree == null) return null;
    side ??= _session.orientation;
    final sans = [for (final move in tree.lineTo(_session.cursor)) move.san];
    final searches = [?_found, ?_mirror, ..._history.reversed];
    // Prefer an exact root, keeping newest-first order within each group.
    // List.sort is not stable, so sorting only by root can show an older run.
    SearchNode? subtree;
    for (final found in searches) {
      if (found.side != side ||
          (request != null && !found.request.compatibleWith(request)))
        continue;
      final node = found.at(tree.rootFen, sans);
      if (node == null) continue;
      if (found.tree.fen == _session.fen) return node;
      subtree ??= node;
    }
    return subtree;
  }

  void _boardChanged() {
    final next = _boardNow;
    if (next == _board) return;
    ++_startTicket;
    final sameDocument = next.$1 == _board?.$1 && next.$3 == _board?.$3;
    _board = next;
    final request = _activeRequest;
    if (!_followEnabled || request == null || (!_active && !_retargeting))
      return;
    if (!sameDocument || _session.shownTo != null) {
      finish();
      _releaseSoon();
      return;
    }
    if (_state case FillRunning(:final stopping) when stopping && !_retargeting)
      return;
    _following = _followBoard(request);
    unawaited(_following);
  }

  /// All navigation uses the same stop/save/restart path. Only the latest
  /// board wins while the previous root is still being saved.
  Future<String?> _followBoard(FillRequest request) async {
    final ticket = ++_startTicket;
    final board = _boardNow;
    final finished = _finished?.future;
    _retargeting = true;
    _finishCurrent();
    _releaseSoon();
    await finished;
    if (_disposed || ticket != _startTicket || board != _boardNow) return null;
    _retargeting = false;
    if (!canStart) return 'Save the previous search before continuing.';
    return start(request);
  }

  Future<String?> followMove(String uci) async {
    _session.playMove(uci);
    return await _following;
  }

  /// Whether a search can start now: a position is on the board and not
  /// hidden, no search is running and no other engine job holds the
  /// machine.
  bool get canStart =>
      !_disposed &&
      !_jobs.heldByOther(this) &&
      !_active &&
      _draftSave == null &&
      !canRetryTree &&
      _lines is! LinesWriting &&
      !running &&
      _session.chapter != null &&
      _session.shownTo == null;

  /// Whether the last run can be written as lines: it was started on a
  /// repertoire chapter this app may write, for the chapter's side, and
  /// is over.
  bool get canMakeLines =>
      !_disposed &&
      _state is FillDone &&
      _found?.chapter != null &&
      _lines is! LinesWriting &&
      _lines is! LinesWritten;

  /// Starts a run, or answers why it did not: the one sentence the screen
  /// shows. Null when it started.
  Future<String?> start(
    FillRequest request, {
    SearchNode? seed,
    SearchNode? mirrorSeed,
  }) async {
    if (_disposed) return 'The search owner is closed.';
    if (_active || running) return 'A search is already running.';
    if (_jobs.heldByOther(this)) {
      return _jobs.blockingMessage;
    }
    if (canRetryTree) return 'Finish saving the previous search tree first.';
    if (_draftSave != null || _lines is LinesWriting) {
      return 'Finish saving the accepted draft first.';
    }
    final chapter = _session.chapter;
    final tree = _session.tree;
    if (chapter == null || tree == null) return 'Nothing is on the board.';
    if (_session.shownTo != null) return 'Finish the puzzle first.';
    final root = positionOf(_session.fen);
    if (root == null) return 'The position on the board cannot be searched.';
    final side = _session.orientation;
    final source = _session.source;
    final line = tree.lineTo(_session.cursor);
    final drafting =
        source != null &&
        chapter.game == null &&
        _session.readOnly == null &&
        chapter.side == side;
    final target = FillTarget(
      rootFen: tree.rootFen,
      cursor: _session.cursor,
      sans: [for (final move in line) move.san],
      side: side,
      chapter: drafting ? (chapter, source) : null,
    );
    ++_startTicket;
    _retargeting = false;
    seed ??= nodeAtBoard(request: request);
    final mirror = request.method == SearchMethod.practical
        ? target.mirror
        : null;
    if (mirror != null) {
      mirrorSeed ??=
          nodeAtBoard(request: request, side: mirror.side) ?? mirrorStart(seed);
    }
    _remember();
    if (_activeRequest?.source != request.source ||
        _activeRequest?.evalDepth != request.evalDepth) {
      // Scores' depths and principal variations share one evaluation scope.
      // A cached score in the next run may supply neither; retaining an old
      // line would silently draft with a different source or depth.
      _engineDepths.clear();
      _bestLines.clear();
    }
    _activeRequest = request;
    _followEnabled = true;
    _active = true;
    _finished = Completer<void>();
    _releasing = null;
    _found = seed == null
        ? null
        : FillFound(target: target, request: request, tree: seed);
    _mirror = mirror == null || mirrorSeed == null
        ? null
        : FillFound(target: mirror, request: request, tree: mirrorSeed);
    _lines = null;
    _draft = null;
    _set(
      FillRunning(
        nodes: seed == null ? 1 : nodesIn(seed),
        depth: 0,
        of: request.depthPlies,
      ),
    );
    _jobs.take(this, 'Paused while searching', kind: EngineJobKind.search);
    try {
      await _run(request, target, root, seed, mirrorSeed);
    } on Object catch (error) {
      log.w('search ${target.label}', error);
      _set(
        const FillFailed('The search could not finish. Try starting it again.'),
      );
    } finally {
      await _finishRun();
    }
    return null;
  }

  /// Continue the newest tree from this board whose settings match, including
  /// after restart: values of different settings are never mixed. With
  /// [orAfresh], the Expectimax button, a board with nothing to continue is
  /// searched from nothing.
  Future<String?> resume(FillRequest request, {bool orAfresh = false}) async {
    if (!canStart) return 'Finish the current search or save first.';
    final ticket = ++_startTicket;
    final board = _boardNow;
    final side = _session.orientation;
    bool moved() => ticket != _startTicket || board != _boardNow || !canStart;
    String changed() => board != _boardNow
        ? 'The board changed while loading the search.'
        : 'The search request changed while loading the saved tree.';
    final seed = await _seedFor(request, side);
    if (moved()) return changed();
    final mirror = request.method == SearchMethod.practical
        ? await _seedFor(request, side.opposite)
        : null;
    if (moved()) return changed();
    final mirrorSeed = mirror is SearchNode ? mirror : null;
    if (seed is SearchNode) {
      return start(request, seed: seed, mirrorSeed: mirrorSeed);
    }
    if (!orAfresh) return seed as String;
    log.i('search afresh: $seed');
    return start(request, mirrorSeed: mirrorSeed);
  }

  /// The tree a search for [side] goes on from at this board: one this
  /// window holds, else the newest saved beside the chapter; or why there
  /// is none.
  Future<Object> _seedFor(FillRequest request, Side side) async {
    if (nodeAtBoard(request: request, side: side) case final node?) return node;
    final source = _session.source;
    final load = _loadTree;
    return source == null || load == null
        ? 'No saved search is available for this board.'
        : savedSeed(load(source, _session.fen), request, side);
  }

  Future<void> _run(
    FillRequest request,
    FillTarget target,
    Position root,
    SearchNode? seed,
    SearchNode? mirrorSeed,
  ) async {
    _answers = null;
    final tools = await _tools(request);
    final Future<void> Function() release;
    switch (tools) {
      case FillUnavailable(:final reason):
        if (!_disposed) _failed('search ${target.label}', reason);
        return;
      case FillReady(release: final done):
        release = done;
      case BookReady():
        release = tools.release;
    }
    // Disposed or cancelled while the engine was starting: dispose and
    // cancel had nothing to release then, so this engine is let go here or
    // its process outlives the run.
    _release = release;
    if (_discarded) {
      await _released();
      _set(const FillIdle());
      return;
    }
    // The other side is searched beside this one, on the same engine, and
    // stops with it unless this one ran its whole depth.
    SearchResult? ended;
    final mirroring = tools is! FillReady
        ? null
        : _buildMirror(
            tools,
            request,
            target.mirror,
            root,
            mirrorSeed,
            stopped: () => ended != null && ended is! SearchComplete,
          );
    final (config, result) = await _build(tools, request, target, root, seed);
    ended = result;
    final mirror = await mirroring;
    await _released();
    if (_disposed) return;
    if (_discarded) {
      _found = _mirror = null;
      _set(const FillIdle());
      return;
    }
    final (tree, stoppedBy, why) = _treeOf(
      result,
      database: request.replies != ReplySource.maia,
    );
    if (tree == null) {
      _failed('search ${target.label}', why!);
      return;
    }
    _show(target, request, tree);
    // A mirror with no move under the board has nothing to show or keep.
    final other = switch (mirror == null ? null : _treeOf(mirror.$2).$1) {
      final OurNode tree => tree,
      final OpponentNode tree => tree,
      _ => null,
    };
    if (other == null) {
      _mirror = null;
    } else {
      _show(target.mirror, request, other, mirror: true);
    }
    final reached = _state is FillRunning ? (_state as FillRunning).depth : 0;
    if (why != null) log.w('search ${target.label}', why);
    log.i('search ${target.label}: ${nodesIn(tree)} positions');
    final done = FillDone(
      nodes: nodesIn(tree),
      depth: result is SearchComplete ? request.depthPlies ?? reached : reached,
      complete: result is SearchComplete,
      budgetReached:
          result is SearchIncomplete && result.reason == StopReason.nodeBudget,
      sourceLost:
          result is SearchIncomplete &&
          result.reason == StopReason.sourceUnavailable,
      stoppedBy: stoppedBy,
    );
    await _publish(target, request, tree, config, result, done, [
      if (other != null) (other, mirror!.$1, mirror.$2 is SearchComplete),
    ]);
  }

  /// The same search for the other side, or null when it could not be made:
  /// its values are an extra, so its failure is logged and never the run's.
  Future<(SearchConfig, SearchResult)?> _buildMirror(
    FillReady tools,
    FillRequest request,
    FillTarget target,
    Position root,
    SearchNode? seed, {
    required CancelSignal stopped,
  }) async {
    try {
      return await _build(
        tools,
        request,
        target,
        root,
        seed,
        mirror: true,
        stopped: () => _stopping || _state is! FillRunning || stopped(),
      );
    } on Object catch (error) {
      log.w('search ${target.label} for ${target.side.name}', error);
      return null;
    }
  }

  /// The tree [tools] build from [root], or from [seed]: the expectimax
  /// search, or the mainline book; and the settings it is saved under.
  Future<(SearchConfig, SearchResult)> _build(
    FillToolsResult tools,
    FillRequest request,
    FillTarget target,
    Position root,
    SearchNode? seed, {
    bool mirror = false,
    CancelSignal? stopped,
  }) async {
    int? lastPly() => switch (_state) {
      FillRunning(:final lastPly) => lastPly,
      _ => null,
    };
    if (tools case BookReady(:final chessDb)) {
      final book = MainlineConfig(
        side: target.side,
        branchPlies: request.depthPlies ?? MainlineConfig.defaultBranchPlies,
      );
      return (
        SearchConfig(
          side: target.side,
          horizonPlies: book.linePlies,
          lossLimitCp: null,
        ),
        await buildMainlineBook(
          root: root,
          seed: seed,
          config: book,
          movesAt: chessDb.bookAt,
          practiceAt: tools.practiceAt,
          isCancelled: () => _stopping,
          lastPly: lastPly,
          onProgress: _progress,
          onSnapshot: (tree) => _show(target, request, tree),
        ),
      );
    }
    final engine = tools as FillReady;
    final config = request.expectimaxFor(
      target.side,
      seeded: seed == null ? 0 : nodesIn(seed),
    );
    return (
      config,
      await buildSearchTree(
        root: root,
        seed: seed,
        config: config,
        evaluator: _answers ??= EngineAnswers(
          engine.evaluator,
          depths: _engineDepths,
          lines: _bestLines,
        ),
        policy: engine.policy,
        candidates: engine.candidates,
        isCancelled: stopped ?? () => _stopping,
        lastPly: lastPly,
        onProgress: mirror ? null : _progress,
        onSnapshot: (tree) => _show(target, request, tree, mirror: mirror),
      ),
    );
  }

  /// Shows the run as done at once, then keeps its tree beside the chapter
  /// and its positions in the Positions list in the background.
  Future<void> _publish(
    FillTarget target,
    FillRequest request,
    SearchNode tree,
    SearchConfig config,
    SearchResult result,
    FillDone done,
    List<(SearchNode, SearchConfig, bool)> mirrors,
  ) async {
    _set(done);
    final source = target.chapter?.$2;
    final keep = _keepTree;
    final saving = <Future<void>>[
      if (finds?.record(
            tree,
            rootFen: target.rootFen,
            prefix: target.sans,
            side: target.side,
            elo: request.elo,
          )
          case final recording?)
        recording.then<void>((_) {}),
      if (source != null && keep != null)
        () async {
          for (final (tree, config, complete) in [
            ...mirrors,
            (tree, config, result is SearchComplete),
          ]) {
            await _saveTree(source, tree, config, complete, request);
          }
        }(),
    ];
    final work = Future.wait(saving).then<void>(
      (_) {},
      onError: (Object error) => log.w('save search results', error),
    );
    _pending.watch(this, work);
    await work;
  }

  Future<void> _saveTree(
    ChapterRef source,
    SearchNode tree,
    SearchConfig config,
    bool complete,
    FillRequest request,
  ) async {
    final runId = newOperationId();
    final bytes = await encodeSearchTree(
      tree,
      config,
      complete: complete,
      evalDepth: request.evalDepth,
      opponentRating: request.treeRating,
      evaluationSource: request.treeSource,
      replySource: request.replyKey,
    );
    final entry = _pending.accept<void>(
      resource: _treeResource,
      label: 'Search tree',
      work: () => _keepTree!(source, bytes, runId: runId),
      problem: (_) => null,
    );
    try {
      await entry.run();
      if (!canRetryTree) treeSaveProblem = null;
    } on Object catch (error) {
      treeSaveProblem = 'The search tree could not be saved. Retry saving it.';
      log.w('save search tree', error);
    }
    if (!_disposed) notifyListeners();
  }

  void _show(
    FillTarget target,
    FillRequest request,
    SearchNode tree, {
    bool mirror = false,
  }) {
    if (_discarded) return;
    final found = FillFound(target: target, request: request, tree: tree);
    if (mirror) {
      _mirror = found;
    } else {
      _found = found;
    }
    notifyListeners();
  }

  /// The tree [result] holds, whole or cut short, and, when the engine or
  /// the model stopped it, a few words for the status line and the full
  /// reason with the position for the log. The tree is null only when the
  /// board itself could not be scored. A [database] of games says why in a
  /// sentence the user can act on (log in, no connection, no games here),
  /// so that is what the status line says.
  (SearchNode?, String?, String?) _treeOf(
    SearchResult result, {
    bool database = false,
  }) => switch (result) {
    SearchComplete(:final tree) ||
    SearchIncomplete(:final tree) => (tree, null, null),
    PolicyMissing(:final fen, :final reason, :final tree) => (
      tree,
      database ? reason : 'the opponent model could not answer',
      'The opponent model could not answer at ${fen.value}: $reason',
    ),
    EvaluationFailed(:final fen, :final reason, :final tree) => (
      tree,
      'the engine could not score a position',
      'The engine could not score ${fen.value}: $reason',
    ),
  };

  /// Writes the last run's best lines, and the traps on them, into a draft
  /// chapter beside the one it was started on. The chapter is read as it
  /// was when the run started: what it already plays is left out.
  Future<void> makeLines() async {
    final found = _found;
    final drafting = found?.chapter;
    if (found == null || drafting == null || !canMakeLines) return;
    final (chapter, source) = drafting;
    _lines = const LinesWriting();
    notifyListeners();
    final work = _writeLines(found, chapter, source).catchError((Object error) {
      log.w('generate repertoire lines', error);
      return (DraftNotWritten('The draft could not be prepared: $error'), 0);
    });
    _pending.watch(this, work);
    final (result, lines) = await work;
    if (_disposed) return;
    if (!identical(_found, found)) {
      log.i('lines from ${source.path}: written for a search since replaced');
      return;
    }
    switch (result) {
      case DraftWritten(:final ref):
        log.i('lines from ${source.path}: $lines in ${ref.path}');
        _lines = LinesWritten(draft: ref, lines: lines);
      case DraftNotWritten(:final reason):
        log.w('lines from ${source.path}', reason);
        _lines = LinesFailed(reason);
    }
    notifyListeners();
  }

  Future<(DraftPublication, int)> _writeLines(
    FillFound found,
    Chapter chapter,
    ChapterRef source,
  ) async {
    if (_draftSave case final saved?) {
      final result = await saved.run();
      if (saved.committed) _draftSave = null;
      return (result, _draftLines);
    }
    final heading = readHeading(chapter.preamble);
    final prefix = chapter.tree.lineTo(found.target.cursor);
    final rootFen = chapter.tree.rootFen;
    final rootMoves = heading.rootFen == rootFen
        ? heading.rootMoves
        : const <String>[];
    final created = _clock();
    final (plan, traps) = await foundIn(
      found.tree,
      known: chapterDecisions(chapter),
    );
    if (plan.lines == 0) {
      return (
        const DraftNotWritten(
          'The search found no line the chapter does not already have.',
        ),
        0,
      );
    }
    final lines = withTraps(plan, traps);
    await _scoreLineEnds(found.request, lineEnds(lines));
    final continued = withContinuations(lines, _bestLines);
    final names = await openings?.load() ?? Openings.none;
    // Checked last, so a chapter moved while line ends were scored is refused;
    // the instant before create is accepted rather than change every store.
    if (_draft == null) {
      final gone = switch (await _store.open(source)) {
        store.Opened() => null,
        store.Absent() =>
          'The chapter was moved, renamed or deleted since '
              'the search. Search again to make lines.',
        store.Unreadable(:final detail) =>
          'The chapter cannot be read: $detail',
      };
      if (gone != null) return (DraftNotWritten(gone), 0);
    }
    final draft = _draft ??= GeneratedDraft(
      documents: _store,
      folder: p.dirname(source.path),
      chapter: source.name,
      textFor: (name) => draftChapterText(
        name: name,
        side: chapter.side,
        rootFen: rootFen,
        rootMoves: rootMoves,
        prefix: prefix,
        plan: continued,
        created: created,
        openings: names,
      ),
    );
    _draftLines = plan.lines;
    final entry = _draftSave = _pending.accept<DraftPublication>(
      resource: draft,
      label: 'Generated draft',
      work: draft.write,
      problem: (result) => result is DraftNotWritten ? result.reason : null,
    );
    final result = await entry.run();
    if (entry.committed) _draftSave = null;
    return (result, plan.lines);
  }

  /// Asks the engine for its best line at each of [ends] this session has
  /// none for — a score the cache answered, or a search resumed from a
  /// saved tree — so every drafted line can be continued. The board's
  /// engine waits meanwhile, as it does for a search. A line whose end the
  /// engine cannot read is written as it is. A mainline book ends where
  /// ChessDB knows no more, and is written so.
  Future<void> _scoreLineEnds(FillRequest request, Set<Fen> ends) async {
    if (request.method == SearchMethod.mainline) return;
    final missing = [
      for (final end in ends)
        if (!_bestLines.containsKey(end.position)) end,
    ];
    // Another job holding the machine keeps it: the lines are written as
    // they are.
    if (missing.isEmpty ||
        !_jobs.take(
          this,
          'Paused while making lines',
          kind: EngineJobKind.makingLines,
        )) {
      return;
    }
    try {
      final tools = await _tools(request);
      if (tools is! FillReady) return;
      try {
        final engine = tools.continuations;
        for (final end in missing) {
          final position = positionOf(end);
          if (engine == null || position == null || _disposed) break;
          await EngineAnswers(
            engine,
            depths: _engineDepths,
            lines: _bestLines,
          ).evaluate(position);
        }
      } finally {
        await tools.release();
      }
    } on Object catch (error) {
      log.w('continue drafted lines', error);
    } finally {
      _jobs.release(this);
    }
  }

  /// Stops the run where it is and forgets it. The engine is handed back at
  /// once so an evaluation in flight comes back empty rather than being
  /// waited for.
  void cancel() {
    _stopFollowing();
    if (_state case final FillRunning running) {
      _set(running.copyWith(cancelling: true));
      _releaseSoon();
    }
  }

  /// Stops the search after the expansion under way and keeps what it has
  /// found: the search goes level by level, so what it has is every move
  /// to the depth it reached. Nothing to do once a stop is asked for.
  void finish() {
    _stopFollowing();
    _finishCurrent();
  }

  void _stopFollowing() {
    _followEnabled = false;
    ++_startTicket;
    _retargeting = false;
  }

  void _finishCurrent() {
    if (_state case final FillRunning running when !running.stopping) {
      _set(running.copyWith(finishing: true));
    }
  }

  /// Lets the level under way finish, every position at the depth the
  /// search has reached scored, then stops and keeps the tree. Asked again
  /// it changes nothing: the level it named is the one it stops after.
  void finishLevel() {
    _stopFollowing();
    if (_state case final FillRunning running
        when !running.stopping && running.lastPly == null) {
      // Before the first expansion is done there is no level to finish but
      // the first.
      _set(running.copyWith(lastPly: running.depth < 1 ? 1 : running.depth));
    }
  }

  /// Every path awaits the same release, including a cancellation that began
  /// cleanup before the search's last engine answer arrived.
  Future<void> _released() {
    if (_releasing case final releasing?) return releasing;
    final release = _release;
    _release = null;
    if (release == null) return Future.value();
    return _releasing = Future<void>.sync(release);
  }

  void _releaseSoon() {
    unawaited(
      _released().catchError((Object error) {
        // The active run still observes this failure and reports it. Detached
        // cancel/dispose must also consume it, rather than create a zone error.
        log.w('release search tools', error);
      }),
    );
  }

  Future<void> _finishRun() async {
    try {
      await _released();
    } on Object catch (error) {
      log.w('release search tools', error);
      _set(
        const FillFailed(
          'The search tools could not close cleanly. Try starting the search again.',
        ),
      );
    } finally {
      _active = false;
      _finished?.complete();
      _jobs.release(this);
      if (!_disposed) notifyListeners();
    }
  }

  void _progress(SearchProgress progress) {
    if (_state case final FillRunning running) {
      _set(running.copyWith(nodes: progress.nodes, depth: progress.depth));
    }
  }

  void _failed(String action, String reason) {
    log.w(action, reason);
    _set(FillFailed(reason));
  }

  void _set(FillState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  /// Another job took or gave back the machine: whether a search may
  /// start has changed.
  void _jobsChanged() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _session.anyChange.removeListener(_boardChanged);
    _jobs.removeListener(_jobsChanged);
    _disposed = true;
    _releaseSoon();
    super.dispose();
  }
}
