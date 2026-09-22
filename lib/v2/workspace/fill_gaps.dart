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

/// What the user asked a fill for: the three knobs of the dialog.
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
}

/// The engine depth every fill scores positions at: the old app's default,
/// and what the shared cache is keyed on.
const fillEvalDepth = 14;

/// The most a move of ours may lose against our best, in centipawns, and
/// still be prepared: the model's own default.
const fillLossLimitCp = 50;

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
  });

  final int nodes;
  final int depth;
  final int of;
  final bool cancelling;
}

/// The draft is written. [name] is the chapter it is in.
final class FillDone extends FillState {
  const FillDone({
    required this.name,
    required this.lines,
    required this.folded,
    required this.alreadyThere,
  });

  final String name;
  final int lines;
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

  /// A tree with more nodes than this is cut into lines on another isolate.
  static const offThreadFrom = 2000;

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
  bool _cancelled = false;
  Future<void> Function()? _release;
  bool _disposed = false;

  FillState get state => _state;

  bool get running => _state is FillRunning;

  /// Whether a fill can start now: a repertoire chapter this app may write
  /// is open, and no fill is running.
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
    if (chapter == null || source == null || chapter.game != null) {
      return 'Open a repertoire chapter to fill.';
    }
    if (_session.readOnly case final reason?) return reason;
    final root = positionOf(_session.fen);
    if (root == null) return 'The position on the board cannot be searched.';
    final cursor = _session.cursor;
    _cancelled = false;
    _set(FillRunning(nodes: 1, depth: 0, of: request.depthPlies));
    _analysis.pause('Paused while filling gaps');
    try {
      await _run(request, chapter, source, cursor, root);
    } finally {
      _analysis.resume();
    }
    return null;
  }

  Future<void> _run(
    FillRequest request,
    Chapter chapter,
    ChapterRef source,
    NodePath cursor,
    Position root,
  ) async {
    final tools = await _tools(request);
    if (_disposed) return;
    switch (tools) {
      case FillUnavailable(:final reason):
        _failed('fill ${source.path}', reason);
        return;
      case FillReady():
        break;
    }
    if (_cancelled) {
      await tools.release();
      _set(const FillIdle());
      return;
    }
    _release = tools.release;
    final config = SearchConfig(
      side: chapter.side,
      horizonPlies: request.depthPlies,
      lossLimitCp: fillLossLimitCp,
      pins: chapterPins(chapter),
      replyFloor: 1 / request.onceIn,
    );
    final result = await buildSearchTree(
      root: root,
      config: config,
      evaluator: tools.evaluator,
      policy: tools.policy,
      isCancelled: () => _cancelled,
      onProgress: _progress,
    );
    await _released();
    if (_disposed) return;
    if (_cancelled) {
      _set(const FillIdle());
      return;
    }
    final SearchNode tree;
    switch (result) {
      case SearchComplete(tree: final built):
        tree = built;
      case SearchIncomplete(tree: final built):
        tree = built;
      case PolicyMissing(:final fen, :final reason):
        _failed(
          'fill ${source.path}',
          'The opponent model could not answer at ${fen.value}: $reason',
        );
        return;
      case EvaluationFailed(:final fen, :final reason):
        _failed(
          'fill ${source.path}',
          'The engine could not score ${fen.value}: $reason',
        );
        return;
    }
    await _written(request, chapter, source, cursor, tree, config, result);
  }

  Future<void> _written(
    FillRequest request,
    Chapter chapter,
    ChapterRef source,
    NodePath cursor,
    SearchNode tree,
    SearchConfig config,
    SearchResult result,
  ) async {
    final known = chapterDecisions(chapter);
    final heading = readHeading(chapter.preamble);
    final prefix = chapter.tree.lineTo(cursor);
    final rootFen = chapter.tree.rootFen;
    final rootMoves = heading.rootFen == rootFen
        ? heading.rootMoves
        : const <String>[];
    final created = _clock();
    final side = chapter.side;
    final folder = p.dirname(source.path);
    var draft = await _draftUnder(
      folder,
      source.name,
      (name) => _Draft.of(
        name: name,
        side: side,
        rootFen: rootFen,
        rootMoves: rootMoves,
        prefix: prefix,
        tree: tree,
        known: known,
        created: created,
      ),
    );
    if (_disposed) return;
    switch (draft) {
      case _DraftWritten(:final ref, :final plan):
        log.i('fill ${source.path}: ${plan.lines} lines in ${ref.path}');
        _set(
          FillDone(
            name: ref.name,
            lines: plan.lines,
            folded: plan.folded,
            alreadyThere: plan.alreadyThere,
          ),
        );
        await _kept(source, tree, config, result, request);
      case _DraftRefused(:final reason):
        _failed('fill ${source.path}', reason);
    }
  }

  /// Writes the draft as the first free name beside [chapter]'s file.
  Future<_DraftOutcome> _draftUnder(
    String folder,
    String chapter,
    Future<_Draft> Function(String name) draft,
  ) async {
    for (var n = 1; n <= _names; n++) {
      final name = n == 1 ? '$chapter (draft)' : '$chapter (draft $n)';
      final ref = ChapterRef.at(p.join(folder, '$name.pgn'));
      final made = await draft(name);
      if (made.plan.lines == 0) {
        return const _DraftRefused(
          'The search found no line the chapter does not already have.',
        );
      }
      switch (await _store.create(ref, made.text)) {
        case store.Created():
          return _DraftWritten(ref, made.plan);
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
    if (_state case FillRunning(:final nodes, :final depth, :final of)) {
      _cancelled = true;
      _set(FillRunning(nodes: nodes, depth: depth, of: of, cancelling: true));
      unawaited(_released());
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
    if (_state case FillRunning(:final of, :final cancelling)) {
      _set(
        FillRunning(
          nodes: progress.nodes,
          depth: progress.depth,
          of: of,
          cancelling: cancelling,
        ),
      );
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

/// The text of one draft and what went into it.
final class _Draft {
  const _Draft(this.text, this.plan);

  final String text;
  final DraftPlan plan;

  /// Cuts [tree] into lines and writes them as chapter text, on another
  /// isolate when the tree is big enough to hold the window otherwise.
  static Future<_Draft> of({
    required String name,
    required Side side,
    required Fen rootFen,
    required List<String> rootMoves,
    required List<MoveNode> prefix,
    required SearchNode tree,
    required Set<String> known,
    required DateTime created,
  }) {
    _Draft build() {
      final plan = planDraft(linesOf(tree), known: known);
      final text = draftChapterText(
        name: name,
        side: side,
        rootFen: rootFen,
        rootMoves: rootMoves,
        prefix: prefix,
        plan: plan,
        created: created,
      );
      return _Draft(text, plan);
    }

    return _nodesIn(tree) < FillGaps.offThreadFrom
        ? Future.value(build())
        : Isolate.run(build);
  }
}

int _nodesIn(SearchNode node) => switch (node) {
  OurNode(:final candidates) =>
    1 + candidates.fold(0, (sum, c) => sum + _nodesIn(c.child)),
  OpponentNode(:final replies) =>
    1 + replies.fold(0, (sum, r) => sum + _nodesIn(r.child)),
  _ => 1,
};

sealed class _DraftOutcome {
  const _DraftOutcome();
}

final class _DraftWritten extends _DraftOutcome {
  const _DraftWritten(this.ref, this.plan);

  final ChapterRef ref;
  final DraftPlan plan;
}

final class _DraftRefused extends _DraftOutcome {
  const _DraftRefused(this.reason);

  final String reason;
}
