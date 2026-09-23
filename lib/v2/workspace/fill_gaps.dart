import 'dart:async';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart' show Position, Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chess/fen.dart';
import '../chess/generation/draft_chapter.dart';
import '../chess/generation/draft_lines.dart';
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
import '../storage/chapter_files.dart';
import '../storage/pgn_document_store.dart' as store;
import 'document_session.dart';
import 'engine_analysis.dart';
import 'fill_found.dart';

/// What the user asked a fill for: the knobs of the dialog.
final class FillRequest {
  const FillRequest({
    required this.elo,
    required this.depthPlies,
    required this.onceIn,
    this.preferTraps = false,
  });

  /// The rating the opponent's replies are predicted for.
  final int elo;

  /// How many half-moves past the board the search plays out.
  final int depthPlies;

  /// A reply reached less than once in this many games is valued where it
  /// stands and not answered.
  final int onceIn;

  /// Whether moves of ours that the engine likes less are tried too, so a
  /// line that sets a trap can win on what the opponent is likely to play.
  final bool preferTraps;

  /// How much a move of ours may lose against our best and still be tried.
  int get lossLimitCp => preferTraps ? trapLossLimitCp : fillLossLimitCp;
}

/// The engine depth every fill scores positions at: the old app's default,
/// and what the shared cache is keyed on.
const fillEvalDepth = 14;

/// The most a move of ours may lose against our best, in centipawns, and
/// still be prepared: the model's own default.
const fillLossLimitCp = 50;

/// The same limit with `Prefer traps` on: a move of ours may give up a pawn
/// and a half when the opponent is likely enough to go wrong after it.
const trapLossLimitCp = 150;

/// What a fill needs and where it comes from: an engine and the model, or
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

/// The run is over and what it found is in [FillGaps.found]. [name] is the
/// draft chapter the lines were written to, or null for a run on the
/// analysis board, which writes nothing.
final class FillDone extends FillState {
  const FillDone({
    required this.name,
    required this.lines,
    required this.traps,
    required this.folded,
    required this.alreadyThere,
  });

  final String? name;
  final int lines;
  final int traps;
  final int folded;
  final int alreadyThere;
}

final class FillFailed extends FillState {
  const FillFailed(this.reason);

  /// A sentence for the screen; the log has the same one.
  final String reason;
}

/// The search that writes proposed lines into a draft chapter beside the
/// one on the board: `Fill gaps from here…`.
///
/// Owns the one run at a time, its progress and what became of it. Reads
/// the [DocumentSession] for the chapter, the side and the position the
/// board is on when the run starts, then works from that snapshot; the user
/// may go on reading meanwhile. Pauses the [EngineAnalysis] for the length
/// of the run, so the two searches do not share one machine. Writes the
/// draft through the store as a new file and never touches the chapter.
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
  int? _picked;
  bool _cancelled = false;
  bool _finishing = false;
  Future<void> Function()? _release;
  bool _disposed = false;

  FillState get state => _state;

  /// What the last finished run found, until the next one starts.
  FillFound? get found => _found;

  /// Which of [FillFound.items] the user last went to, for ↑ and ↓.
  int? get picked => _picked;

  bool get running => _state is FillRunning;

  /// Whether a fill can start now: a repertoire chapter this app may write,
  /// or the analysis board, is open, and no fill is running.
  bool get canStart =>
      !running &&
      _session.chapter != null &&
      _session.game == null &&
      _session.readOnly == null;

  /// Starts a run, or answers why it did not: the one sentence the screen
  /// shows. Null when it started.
  Future<String?> start(FillRequest request) async {
    if (running) return 'A fill is already running.';
    final chapter = _session.chapter;
    final source = _session.source;
    final onBoard = _session.isScratch;
    if (chapter == null ||
        chapter.game != null ||
        (source == null && !onBoard)) {
      return 'Open a repertoire chapter or the analysis board first.';
    }
    if (_session.readOnly case final reason?) return reason;
    final root = positionOf(_session.fen);
    if (root == null) return 'The position on the board cannot be searched.';
    final target = source == null
        ? FillTarget.board(chapter, _session.cursor, _session.orientation)
        : FillTarget.chapter(chapter, source, _session.cursor);
    _cancelled = false;
    _finishing = false;
    _found = null;
    _picked = null;
    _set(FillRunning(nodes: 1, depth: 0, of: request.depthPlies));
    _analysis.pause('Paused while searching');
    try {
      await _run(request, target, root);
    } finally {
      _analysis.resume();
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
        if (!_disposed) _failed('fill ${target.label}', reason);
        return;
      case FillReady():
        break;
    }
    // Disposed or cancelled while the engine was starting: dispose and
    // cancel had nothing to release then, so this engine is let go here or
    // its process outlives the run.
    if (_cancelled || _disposed) {
      await tools.release();
      _set(const FillIdle());
      return;
    }
    _release = tools.release;
    final config = SearchConfig(
      side: target.side,
      horizonPlies: request.depthPlies,
      lossLimitCp: request.lossLimitCp,
      pins: target.pins,
      replyFloor: 1 / request.onceIn,
    );
    final result = await buildSearchTree(
      root: root,
      config: config,
      evaluator: tools.evaluator,
      policy: tools.policy,
      isCancelled: () => _cancelled || _finishing,
      onProgress: _progress,
    );
    await _released();
    if (_disposed) return;
    if (_cancelled) {
      _set(const FillIdle());
      return;
    }
    final tree = _treeOf(result, target);
    if (tree == null) return;
    switch (target) {
      case BoardTarget():
        await _shown(target, tree);
      case ChapterTarget():
        await _written(request, target, tree, config, result);
    }
  }

  /// The tree [result] holds, whole or cut short; null, with the run marked
  /// failed, when the engine or the model gave up.
  SearchNode? _treeOf(SearchResult result, FillTarget target) {
    switch (result) {
      case SearchComplete(:final tree) || SearchIncomplete(:final tree):
        return tree;
      case PolicyMissing(:final fen, :final reason):
        _failed(
          'fill ${target.label}',
          'The opponent model could not answer at ${fen.value}: $reason',
        );
      case EvaluationFailed(:final fen, :final reason):
        _failed(
          'fill ${target.label}',
          'The engine could not score ${fen.value}: $reason',
        );
    }
    return null;
  }

  /// A run on the analysis board writes nothing: what it found is kept for
  /// the Prep tab, which plays a result onto the board when it is asked to.
  Future<void> _shown(BoardTarget target, SearchNode tree) async {
    final found = await foundIn(tree, known: const {});
    if (_disposed) return;
    final (plan, traps) = found;
    if (plan.lines == 0 && traps.isEmpty) {
      _failed('fill ${target.label}', 'The search found no line to show.');
      return;
    }
    _found = FillFound(
      origin: OnTheBoard(root: target.rootFen, line: target.line),
      side: target.side,
      traps: traps,
      lines: [for (final entry in plan.entries) entry.line],
    );
    log.i('fill on the board: ${plan.lines} lines, ${traps.length} traps');
    _set(
      FillDone(
        name: null,
        lines: plan.lines,
        traps: traps.length,
        folded: plan.folded,
        alreadyThere: 0,
      ),
    );
  }

  Future<void> _written(
    FillRequest request,
    ChapterTarget target,
    SearchNode tree,
    SearchConfig config,
    SearchResult result,
  ) async {
    final chapter = target.chapter;
    final source = target.source;
    final known = chapterDecisions(chapter);
    final heading = readHeading(chapter.preamble);
    final prefix = chapter.tree.lineTo(target.cursor);
    final rootFen = chapter.tree.rootFen;
    final rootMoves = heading.rootFen == rootFen
        ? heading.rootMoves
        : const <String>[];
    final created = _clock();
    final side = chapter.side;
    final folder = p.dirname(source.path);
    final (plan, traps) = await foundIn(tree, known: known);
    if (_disposed) return;
    final draft = await _draftUnder(
      folder,
      source.name,
      plan,
      (name) => draftChapterText(
        name: name,
        side: side,
        rootFen: rootFen,
        rootMoves: rootMoves,
        prefix: prefix,
        plan: withTraps(plan, traps),
        created: created,
      ),
    );
    if (_disposed) return;
    switch (draft) {
      case _DraftWritten(:final ref):
        log.i('fill ${source.path}: ${plan.lines} lines in ${ref.path}');
        _found = FillFound(
          origin: InDraft(
            draft: ref,
            sans: [for (final move in prefix) move.san],
          ),
          side: side,
          traps: traps,
          lines: [for (final entry in plan.entries) entry.line],
        );
        _set(
          FillDone(
            name: ref.name,
            lines: plan.lines,
            traps: traps.length,
            folded: plan.folded,
            alreadyThere: plan.alreadyThere,
          ),
        );
        await _kept(source, tree, config, result, request);
      case _DraftRefused(:final reason):
        _failed('fill ${source.path}', reason);
    }
  }

  /// Notes that the user went to the item at [index] of [found]'s items.
  void pick(int index) {
    final count = _found?.items.length ?? 0;
    if (index < 0 || index >= count || index == _picked) return;
    _picked = index;
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

  /// Stops the run where it is. Nothing is written; the engine is handed
  /// back at once so an evaluation in flight comes back empty rather than
  /// being waited for.
  void cancel() {
    if (_state case final FillRunning running) {
      _cancelled = true;
      _set(running.copyWith(cancelling: true));
      unawaited(_released());
    }
  }

  /// Stops the search after the expansion under way and shows what it has
  /// found so far: the search goes level by level, so what it has is every
  /// line to the depth it reached. Nothing to do once a stop is asked for.
  void finish() {
    if (_state case final FillRunning running when !running.stopping) {
      _finishing = true;
      _set(running.copyWith(finishing: true));
    }
  }

  /// Takes the last outcome off the card.
  void dismiss() {
    if (_state is FillDone || _state is FillFailed) _set(const FillIdle());
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
    _cancelled = true;
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

/// Where a run began and what it may write: a chapter, which gets a draft
/// beside it, or the analysis board, which gets nothing written.
sealed class FillTarget {
  const FillTarget();

  factory FillTarget.chapter(Chapter chapter, ChapterRef source, NodePath at) =
      ChapterTarget;

  factory FillTarget.board(Chapter board, NodePath at, Side side) = BoardTarget;

  Side get side;

  /// The moves already decided, which the search keeps rather than asks.
  Map<String, Set<String>> get pins;

  /// How the log names the run.
  String get label;
}

final class ChapterTarget extends FillTarget {
  const ChapterTarget(this.chapter, this.source, this.cursor);

  final Chapter chapter;
  final ChapterRef source;
  final NodePath cursor;

  @override
  Side get side => chapter.side;

  /// The chapter's own moves: at a position it answers, only its moves are
  /// tried, so a fill continues the chapter rather than second-guessing it.
  @override
  Map<String, Set<String>> get pins => chapterPins(chapter);

  @override
  String get label => source.path;
}

/// The analysis board, for the side at the bottom of it. Nothing on the
/// board is a decision: it is a scratchpad, so nothing is pinned.
final class BoardTarget extends FillTarget {
  BoardTarget(Chapter board, NodePath cursor, this.side)
    : rootFen = board.tree.rootFen,
      line = [
        for (final move in board.tree.lineTo(cursor))
          MoveRef(uci: move.uci, san: move.san),
      ];

  final Fen rootFen;
  final List<MoveRef> line;

  @override
  final Side side;

  @override
  Map<String, Set<String>> get pins => const {};

  @override
  String get label => 'the analysis board';
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
