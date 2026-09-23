import 'dart:async';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart' show Position, Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chess/fen.dart';
import '../chess/generation/draft_chapter.dart';
import '../chess/generation/draft_lines.dart';
import '../chess/generation/eval.dart';
import '../chess/generation/search.dart';
import '../chess/generation/search_config.dart';
import '../chess/generation/search_node.dart';
import '../chess/generation/search_result.dart';
import '../chess/generation/sources.dart';
import '../chess/generation/traps.dart';
import '../chess/generation/tree_wire_v4.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_heading.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/tree_edit.dart' show positionOf;
import '../diagnostics/log.dart';
import '../engines/maia/move_policy.dart';
import '../storage/chapter_files.dart';
import '../storage/eval_cache.dart';
import '../storage/pgn_document_store.dart' as store;
import 'document_session.dart';
import 'engine_analysis.dart';

/// What a search is asked for: the three numbers of the Search tab.
final class FillRequest {
  const FillRequest({
    required this.elo,
    required this.depthPlies,
    required this.onceIn,
  });

  /// The rating the opponent's replies are predicted for.
  final int elo;

  /// How many half-moves past the board the search plays out.
  final int depthPlies;

  /// A reply reached less than once in this many games is valued where it
  /// stands and not answered.
  final int onceIn;

  /// How much a move of ours may lose against our best and still be tried.
  int get lossLimitCp => fillLossLimitCp;
}

/// The engine depth every search scores positions at: the old app's
/// default, and what the shared cache is keyed on.
const fillEvalDepth = 14;

/// The most a move of ours may lose against our best, in centipawns, and
/// still be searched: the model's own default.
const fillLossLimitCp = 50;

/// How deep a search looks unless the user says otherwise, and the range
/// it may be set to.
const defaultSearchDepth = 8;
const minFillDepth = 1;
const maxFillDepth = 64;

/// What a search needs and where it comes from: an engine and the model, or
/// why there are none.
sealed class FillToolsResult {
  const FillToolsResult();
}

final class FillReady extends FillToolsResult {
  const FillReady({
    required this.evaluator,
    required this.policy,
    required this.release,
  });

  final PositionEvaluator evaluator;
  final OpponentPolicy policy;

  /// Hands the engine back; called once, when the run is over or cancelled.
  final Future<void> Function() release;
}

final class FillUnavailable extends FillToolsResult {
  const FillUnavailable(this.reason);

  /// A sentence for the screen.
  final String reason;
}

typedef FillToolsFactory = Future<FillToolsResult> Function(FillRequest);

/// Keeps the tree a finished run built beside the chapter it was started
/// from, for a later run to extend. Given the chapter file and the tree's
/// text; never throws to the caller.
typedef TreeKeeper = Future<void> Function(ChapterRef chapter, String tree);

sealed class FillState {
  const FillState();
}

final class FillIdle extends FillState {
  const FillIdle();
}

final class FillRunning extends FillState {
  const FillRunning({
    required this.nodes,
    required this.depth,
    required this.of,
    this.cancelling = false,
    this.finishing = false,
  });

  final int nodes;
  final int depth;
  final int of;
  final bool cancelling;

  /// Asked to stop and keep what it has: the expansion under way is
  /// finished, then the tree as it stands is read.
  final bool finishing;

  /// Whether a stop has been asked for, either kind.
  bool get stopping => cancelling || finishing;

  FillRunning copyWith({
    int? nodes,
    int? depth,
    bool? cancelling,
    bool? finishing,
  }) => FillRunning(
    nodes: nodes ?? this.nodes,
    depth: depth ?? this.depth,
    of: of,
    cancelling: cancelling ?? this.cancelling,
    finishing: finishing ?? this.finishing,
  );
}

/// The run is over and its tree is in [FillGaps.found]: [depth] half-moves
/// deep over [nodes] positions, the whole way when [complete].
final class FillDone extends FillState {
  const FillDone({
    required this.nodes,
    required this.depth,
    required this.complete,
  });

  final int nodes;
  final int depth;
  final bool complete;
}

final class FillFailed extends FillState {
  const FillFailed(this.reason);

  /// A sentence for the screen; the log has the same one.
  final String reason;
}

/// What became of turning a chapter's search into lines.
sealed class LinesState {
  const LinesState();
}

final class LinesWriting extends LinesState {
  const LinesWriting();
}

/// The lines are in the draft chapter [draft].
final class LinesWritten extends LinesState {
  const LinesWritten({required this.draft, required this.lines});

  final ChapterRef draft;
  final int lines;
}

final class LinesFailed extends LinesState {
  const LinesFailed(this.reason);

  final String reason;
}

/// The expectimax search from the board: the Search tab.
///
/// Owns the one run at a time, its progress and the tree it built, which
/// the Search tab reads as the board moves: a search only gets the values.
/// Reads the [DocumentSession] for the position, the line to it and the
/// side at the bottom of the board when the run starts, then works from that
/// snapshot; the user may go on reading meanwhile, and the tree so far is
/// shown as each level of it is done. Pauses the [EngineAnalysis] for the
/// length of the run, so the two searches do not share one machine.
///
/// On a repertoire chapter the values can then be turned into lines: a
/// draft chapter written through the store as a new file beside it. The
/// chapter itself is never touched.
final class FillGaps extends ChangeNotifier {
  FillGaps({
    required DocumentSession session,
    required EngineAnalysis analysis,
    required store.PgnDocumentStore documents,
    required FillToolsFactory tools,
    TreeKeeper? keepTree,
    DateTime Function() clock = DateTime.now,
  }) : _session = session,
       _analysis = analysis,
       _store = documents,
       _tools = tools,
       _keepTree = keepTree,
       _clock = clock;

  /// How many draft names are tried before giving up: `X (draft)`,
  /// `X (draft 2)`, … A user with this many drafts of one chapter has
  /// something other than a name clash to sort out.
  static const _names = 20;

  final DocumentSession _session;
  final EngineAnalysis _analysis;
  final store.PgnDocumentStore _store;
  final FillToolsFactory _tools;
  final TreeKeeper? _keepTree;
  final DateTime Function() _clock;

  FillState _state = const FillIdle();
  FillFound? _found;
  LinesState? _lines;
  Future<void> Function()? _release;
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

  /// How many half-moves deep the next search looks: the Search tab's
  /// number, kept for the life of the window.
  int depth = defaultSearchDepth;

  /// Whether a search can start now: a position is on the board and not
  /// hidden, and no search is running.
  bool get canStart =>
      !running && _session.chapter != null && _session.shownTo == null;

  /// Whether the last run can be written as lines: it was started on a
  /// repertoire chapter this app may write, for the chapter's side, and
  /// is over.
  bool get canMakeLines =>
      _state is FillDone &&
      _found?.chapter != null &&
      _lines is! LinesWriting &&
      _lines is! LinesWritten;

  /// Starts a run, or answers why it did not: the one sentence the screen
  /// shows. Null when it started.
  Future<String?> start(FillRequest request) async {
    if (running) return 'A search is already running.';
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
    _found = null;
    _lines = null;
    _set(FillRunning(nodes: 1, depth: 0, of: request.depthPlies));
    _analysis.pause(this, 'Paused while searching');
    try {
      await _run(request, target, root);
    } finally {
      _analysis.resume(this);
    }
    return null;
  }

  Future<void> _run(
    FillRequest request,
    FillTarget target,
    Position root,
  ) async {
    final tools = await _tools(request);
    switch (tools) {
      case FillUnavailable(:final reason):
        if (!_disposed) _failed('search ${target.label}', reason);
        return;
      case FillReady():
        break;
    }
    // Disposed or cancelled while the engine was starting: dispose and
    // cancel had nothing to release then, so this engine is let go here or
    // its process outlives the run.
    if (_discarded) {
      await tools.release();
      _set(const FillIdle());
      return;
    }
    _release = tools.release;
    final config = SearchConfig(
      side: target.side,
      horizonPlies: request.depthPlies,
      lossLimitCp: request.lossLimitCp,
      replyFloor: 1 / request.onceIn,
    );
    final result = await buildSearchTree(
      root: root,
      config: config,
      evaluator: tools.evaluator,
      policy: tools.policy,
      isCancelled: () => _stopping,
      onProgress: _progress,
      onSnapshot: (tree) => _show(target, request, tree),
    );
    await _released();
    if (_disposed) return;
    if (_discarded) {
      _found = null;
      _set(const FillIdle());
      return;
    }
    final tree = _treeOf(result, target);
    if (tree == null) return;
    _show(target, request, tree);
    final reached = _state is FillRunning ? (_state as FillRunning).depth : 0;
    log.i('search ${target.label}: ${nodesIn(tree)} positions');
    _set(
      FillDone(
        nodes: nodesIn(tree),
        depth: result is SearchComplete ? request.depthPlies : reached,
        complete: result is SearchComplete,
      ),
    );
    if (target.chapter case (_, final source)) {
      await _kept(source, tree, config, result, request);
    }
  }

  void _show(FillTarget target, FillRequest request, SearchNode tree) {
    if (_discarded) return;
    _found = FillFound(target: target, request: request, tree: tree);
    notifyListeners();
  }

  /// The tree [result] holds, whole or cut short; null, with the run marked
  /// failed, when the engine or the model gave up.
  SearchNode? _treeOf(SearchResult result, FillTarget target) {
    switch (result) {
      case SearchComplete(:final tree) || SearchIncomplete(:final tree):
        return tree;
      case PolicyMissing(:final fen, :final reason):
        _failed(
          'search ${target.label}',
          'The opponent model could not answer at ${fen.value}: $reason',
        );
      case EvaluationFailed(:final fen, :final reason):
        _failed(
          'search ${target.label}',
          'The engine could not score ${fen.value}: $reason',
        );
    }
    return null;
  }

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
    final known = chapterDecisions(chapter);
    final heading = readHeading(chapter.preamble);
    final prefix = chapter.tree.lineTo(found.target.cursor);
    final rootFen = chapter.tree.rootFen;
    final rootMoves = heading.rootFen == rootFen
        ? heading.rootMoves
        : const <String>[];
    final created = _clock();
    final (plan, traps) = await foundIn(found.tree, known: known);
    // Another search started meanwhile, and what it finds is the one on
    // show: this run's lines are not written.
    if (_disposed || !identical(_found, found)) return;
    final draft = await _draftUnder(
      p.dirname(source.path),
      source.name,
      plan,
      (name) => draftChapterText(
        name: name,
        side: chapter.side,
        rootFen: rootFen,
        rootMoves: rootMoves,
        prefix: prefix,
        plan: withTraps(plan, traps),
        created: created,
      ),
    );
    if (_disposed) return;
    if (!identical(_found, found)) {
      log.i('lines from ${source.path}: written for a search since replaced');
      return;
    }
    switch (draft) {
      case _DraftWritten(:final ref):
        log.i('lines from ${source.path}: ${plan.lines} in ${ref.path}');
        _lines = LinesWritten(draft: ref, lines: plan.lines);
      case _DraftRefused(:final reason):
        log.w('lines from ${source.path}', reason);
        _lines = LinesFailed(reason);
    }
    notifyListeners();
  }

  /// Writes the draft as the first free name beside [chapter]'s file.
  Future<_DraftOutcome> _draftUnder(
    String folder,
    String chapter,
    DraftPlan plan,
    String Function(String name) draft,
  ) async {
    if (plan.lines == 0) {
      return const _DraftRefused(
        'The search found no line the chapter does not already have.',
      );
    }
    for (var n = 1; n <= _names; n++) {
      final name = n == 1 ? '$chapter (draft)' : '$chapter (draft $n)';
      final ref = ChapterRef.at(p.join(folder, '$name.pgn'));
      switch (await _store.create(ref, draft(name))) {
        case store.Created():
          return _DraftWritten(ref);
        case store.Collision():
          continue;
        case store.IoFailure(:final detail):
          return _DraftRefused('The draft could not be written: $detail');
      }
    }
    return const _DraftRefused(
      'Too many drafts of this chapter already; delete some first.',
    );
  }

  Future<void> _kept(
    ChapterRef source,
    SearchNode tree,
    SearchConfig config,
    SearchResult result,
    FillRequest request,
  ) async {
    final keep = _keepTree;
    if (keep == null) return;
    try {
      final text = encodeTreeV4(
        tree,
        config,
        complete: result is SearchComplete,
        evalDepth: fillEvalDepth,
        opponentRating: request.elo,
      );
      await keep(source, text);
    } on Object catch (error) {
      log.w('keep the tree of ${source.path}', error);
    }
  }

  /// Stops the run where it is and forgets it. The engine is handed back at
  /// once so an evaluation in flight comes back empty rather than being
  /// waited for.
  void cancel() {
    if (_state case final FillRunning running) {
      _set(running.copyWith(cancelling: true));
      unawaited(_released());
    }
  }

  /// Stops the search after the expansion under way and keeps what it has
  /// found: the search goes level by level, so what it has is every move
  /// to the depth it reached. Nothing to do once a stop is asked for.
  void finish() {
    if (_state case final FillRunning running when !running.stopping) {
      _set(running.copyWith(finishing: true));
    }
  }

  Future<void> _released() async {
    final release = _release;
    _release = null;
    if (release != null) await release();
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

  @override
  void dispose() {
    _disposed = true;
    unawaited(_released());
    super.dispose();
  }
}

sealed class _DraftOutcome {
  const _DraftOutcome();
}

final class _DraftWritten extends _DraftOutcome {
  const _DraftWritten(this.ref);

  final ChapterRef ref;
}

final class _DraftRefused extends _DraftOutcome {
  const _DraftRefused(this.reason);

  final String reason;
}

/// A tree with more nodes than this is cut into lines on another isolate.
const offThreadFrom = 2000;

/// Where a run began: the document's root and the moves from it to the
/// board, the side searched for, and — when the run can become lines —
/// the chapter as it was and its file.
final class FillTarget {
  const FillTarget({
    required this.rootFen,
    required this.cursor,
    required this.sans,
    required this.side,
    this.chapter,
  });

  final Fen rootFen;
  final NodePath cursor;
  final List<String> sans;
  final Side side;
  final (Chapter, ChapterRef)? chapter;

  /// How the log names the run.
  String get label => chapter?.$2.path ?? 'the board';
}

/// The lines [tree] proposes, cut as a draft is, and its traps; worked out
/// on another isolate when the tree is big enough to hold the window
/// otherwise.
Future<(DraftPlan, List<Trap>)> foundIn(
  SearchNode tree, {
  required Set<String> known,
}) {
  (DraftPlan, List<Trap>) work() =>
      (planDraft(linesOf(tree), known: known), trapsOf(tree));
  return nodesIn(tree) < offThreadFrom
      ? Future.value(work())
      : Isolate.run(work);
}

int nodesIn(SearchNode node) => switch (node) {
  OurNode(:final candidates) =>
    1 + candidates.fold(0, (sum, c) => sum + nodesIn(c.child)),
  OpponentNode(:final replies) =>
    1 + replies.fold(0, (sum, r) => sum + nodesIn(r.child)),
  _ => 1,
};

/// The tree of the last run, where it was started and what it was asked.
final class FillFound {
  const FillFound({
    required this.target,
    required this.request,
    required this.tree,
  });

  final FillTarget target;
  final FillRequest request;

  /// The search tree from the position the run started at.
  final SearchNode tree;

  Side get side => target.side;

  /// The chapter the run can be written into as lines, and its file.
  (Chapter, ChapterRef)? get chapter => target.chapter;

  /// The node for the position reached from [root] by [sans], or null when
  /// that position is not in the search: another document, a line that
  /// leaves the tree, or a position before the one the run started at.
  SearchNode? at(Fen root, List<String> sans) {
    if (root != target.rootFen || sans.length < target.sans.length) {
      return null;
    }
    for (final (i, san) in target.sans.indexed) {
      if (sans[i] != san) return null;
    }
    SearchNode node = tree;
    for (final san in sans.skip(target.sans.length)) {
      final next = switch (node) {
        OurNode(:final candidates) =>
          candidates.where((c) => c.move.san == san).firstOrNull?.child,
        OpponentNode(:final replies) =>
          replies.where((r) => r.move.san == san).firstOrNull?.child,
        _ => null,
      };
      if (next == null) return null;
      node = next;
    }
    return node;
  }
}

/// The engine with the cache in front of it: a position the cache holds at
/// the depth asked for is answered from there, and every verdict the engine
/// gives is written back, from White's side, so a later run of either app
/// finds it.
///
/// The engine answers from the side to move and the cache keeps White's
/// view, so one negation each way when it is Black's move.
final class CachedEvaluator implements PositionEvaluator {
  const CachedEvaluator(this.engine, this.cache, {required this.depth});

  final PositionEvaluator engine;
  final EvalCache cache;
  final int depth;

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    final fen = Fen(position.fen);
    final white = position.turn == Side.white;
    final kept = cache.read(fen.position, minDepth: depth);
    if (kept != null) return Evaluated(Eval(white ? kept : -kept));
    final answer = await evaluationOf(engine, position);
    if (answer case Evaluated(:final eval)) {
      cache.write(
        fen.position,
        cpWhite: white ? eval.cp : -eval.cp,
        depth: depth,
      );
    }
    return answer;
  }
}

/// The Maia model as the search's opponent, at one rating.
///
/// The model answers with shares over the legal moves, most likely first,
/// which is already a policy; a position it cannot read is a position the
/// search stops at, as the algorithm requires.
final class MaiaOpponent implements OpponentPolicy {
  const MaiaOpponent(this.model, {required this.elo});

  final MovePolicy model;
  final int elo;

  @override
  Future<PolicyResult> policyFor(Position position) async =>
      switch (await model.policy(Fen(position.fen), elo)) {
        MaiaPolicy(:final shares) => PolicyFound(Policy(shares)),
        MaiaFailed(:final reason) => PolicyUnavailable(reason),
      };
}
