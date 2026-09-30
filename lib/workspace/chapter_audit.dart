import 'dart:async';

import 'package:dartchess/dartchess.dart' show Position;
import 'package:flutter/foundation.dart';

import '../chess/audit/chapter_audit.dart';
import '../chess/fen.dart';
import '../chess/generation/draft_chapter.dart' show standardCastling;
import '../chess/generation/sources.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/tree_edit.dart' show pathOfSans, positionOf;
import '../chess/pv_text.dart';
import '../diagnostics/log.dart';
import '../engines/engine.dart';
import '../engines/engine_supervisor.dart';
import '../engines/fixed_depth.dart';
import '../net/chessdb_moves.dart';
import '../net/remote_queue.dart';
import '../storage/audit_store.dart';
import '../storage/chapter_files.dart';
import '../storage/eval_cache.dart';
import '../storage/settings_store.dart';
import 'document_session.dart';
import 'engine_jobs.dart';
import 'fill_states.dart' show fillEvalDepth;
import 'gap_hunt.dart';
import 'gap_walk.dart';
import 'replies.dart';

sealed class AuditState {
  const AuditState();
}

/// No audit has run on the chapter on the board.
final class AuditIdle extends AuditState {
  const AuditIdle();
}

final class AuditRunning extends AuditState {
  const AuditRunning({
    required this.checked,
    required this.of,
    this.stopping = false,
  });

  final int checked;
  final int of;
  final bool stopping;
}

/// The audit judged [checked] of [of] positions: all of them unless it was
/// stopped, the engine went away or it could not rank one. [chessDbDropped]
/// says ChessDB stopped answering on the way, so the replies only it would
/// have named are missing.
final class AuditDone extends AuditState {
  const AuditDone({
    required this.checked,
    required this.of,
    this.chessDbDropped = false,
  });

  final int checked;
  final int of;
  final bool chessDbDropped;

  bool get complete => checked == of && !chessDbDropped;
}

final class AuditFailed extends AuditState {
  const AuditFailed(this.reason);

  /// A sentence for the screen; the log has the same one.
  final String reason;
}

/// The Audit tab's owner: the chapter on the board checked against the
/// engine, and what it found.
///
/// A run takes the chapter as it is when started and walks its positions
/// breadth first (`chess/audit/chapter_audit.dart` says what is judged). The
/// engine's lines at each position are kept in the [AuditStore] and the
/// scores after a move in the shared evaluation cache, so auditing again —
/// after Stop, after an edit, after a restart — asks the engine only about
/// what is new, and a chapter nothing changed in needs no engine at all.
/// One run at a time, and none while another engine job holds the machine
/// ([EngineJobs]); the board's engine waits while it runs.
///
/// Before the engine is asked, the chapter is walked as the Replies tab
/// walks it — [walkGaps] over what the repertoire answers
/// ([RepertoireAnswers] and [answeredPositions]) at the floor the settings
/// name — so the reach of each position, and which replies are the Replies
/// tab's, are the walk's own: the two tabs cannot disagree about either.
///
/// Findings follow the chapter as it is now: a strong reply the user has
/// since answered, or a move they deleted, drops out of [findings] with no
/// new run. A dismissed finding stays dismissed wherever that move is met.
final class ChapterAudit extends ChangeNotifier {
  ChapterAudit({
    required DocumentSession session,
    required EngineJobs jobs,
    required Future<EngineStart> Function() launch,
    required EvalCache Function() evalCache,
    required AuditStore Function() store,
    required ReplyModel model,
    required SettingsStore settings,
    required RepertoireAnswers answers,
    required RemoteQueue lookups,
  }) : _session = session,
       _jobs = jobs,
       _launch = launch,
       _evalCache = evalCache,
       _storeOf = store,
       _model = model,
       _settings = settings,
       _answers = answers,
       _lookups = lookups {
    _session.addListener(_documentChanged);
    _jobs.addListener(_jobsChanged);
  }

  final DocumentSession _session;
  final EngineJobs _jobs;
  final Future<EngineStart> Function() _launch;
  final EvalCache Function() _evalCache;
  final AuditStore Function() _storeOf;
  final ReplyModel _model;
  final SettingsStore _settings;
  final RepertoireAnswers _answers;
  final RemoteQueue _lookups;

  AuditState _state = const AuditIdle();
  AuditState get state => _state;

  /// Whether the next run also asks ChessDB for strong replies. Off unless
  /// the user turns it on: it sends the chapter's positions over the
  /// network.
  bool askChessDb = false;

  /// The chapter the findings are about, and every one found.
  ChapterRef? _audited;
  var _found = <AuditFinding>[];
  var _dismissed = <String>{};
  int _ticket = 0;
  bool _disposed = false;

  /// The run that holds the machine: until its engine is gone, even after
  /// another chapter overtook it, so no second audit starts beside it.
  _Run? _holding;

  bool get running => _state is AuditRunning;

  /// Whether a dismissal or a restore could not be written: what was put
  /// aside, or brought back, lasts only as long as this window.
  bool get dismissalsNotKept => _dismissalsNotKept;
  bool _dismissalsNotKept = false;

  /// Whether an audit can start: a repertoire chapter is on the board, no
  /// audit is running and the engine is not held by another job, an
  /// overtaken run of this audit's own included.
  bool get canStart =>
      !_disposed &&
      !running &&
      _session.source != null &&
      _session.chapter?.game == null &&
      _session.shownTo == null &&
      !_jobs.heldByOther(this);

  /// What the audit found that still stands in the chapter as it is now
  /// and was not dismissed, most reached first.
  List<AuditFinding> get findings {
    final tree = _session.tree;
    if (tree == null || _session.source != _audited) return const [];
    return [
      for (final finding in _found)
        if (!_dismissed.contains(finding.key) && _stands(tree, finding))
          finding,
    ];
  }

  /// How many of the findings for this chapter were put aside.
  int get dismissedCount =>
      _found.where((finding) => _dismissed.contains(finding.key)).length;

  /// A weak move stands while the chapter still plays it; a strong reply
  /// while the chapter still does not answer it.
  bool _stands(GameTree tree, AuditFinding finding) {
    final path = pathOfSans(tree, finding.sans);
    if (path == null) return false;
    final moves = path.isRoot ? tree.children : tree.nodeAt(path)!.children;
    final plays = moves.any(
      (move) =>
          (standardCastling(move.uci, finding.fen) ?? move.uci) == finding.uci,
    );
    return switch (finding) {
      WeakMove() => plays,
      StrongReply() => !plays,
    };
  }

  /// Puts the board on the position the finding is about, before its move.
  void goTo(AuditFinding finding) {
    final tree = _session.tree;
    final path = tree == null ? null : pathOfSans(tree, finding.sans);
    if (path != null) _session.goTo(path);
  }

  void dismiss(AuditFinding finding) {
    if (_audited == null || !_dismissed.add(finding.key)) return;
    if (!_storeOf().dismiss(finding.key)) _dismissalsNotKept = true;
    notifyListeners();
  }

  /// Brings back the findings of this chapter that were put aside.
  void restoreDismissed() {
    final keys = [
      for (final finding in _found)
        if (_dismissed.contains(finding.key)) finding.key,
    ];
    if (keys.isEmpty) return;
    _dismissed.removeAll(keys);
    if (!_storeOf().restore(keys)) _dismissalsNotKept = true;
    notifyListeners();
  }

  /// Stops after the position under way, keeping what was found.
  void stop() {
    if (_state case AuditRunning(:final checked, :final of, stopping: false)) {
      _set(AuditRunning(checked: checked, of: of, stopping: true));
    }
  }

  /// Audits the chapter on the board, or answers why not.
  Future<String?> start() async {
    if (!canStart) {
      return running
          ? 'The audit is already running.'
          : _jobs.heldByOther(this)
          ? 'Wait for the engine job under way to finish.'
          : 'Open a repertoire chapter to audit it.';
    }
    final chapter = _session.chapter!;
    final source = _session.source!;
    final positions = auditPositions(chapter.tree, chapter.side);
    final ticket = ++_ticket;
    _dismissed = _storeOf().dismissed();
    _audited = source;
    _found = [];
    _set(AuditRunning(checked: 0, of: positions.length));
    final run = _Run(
      positions: positions,
      chessDb: askChessDb ? ChessDbMoves(_lookups.run()) : null,
    );
    _jobs.take(run, 'Paused while auditing');
    _holding = run;
    try {
      final walk = await _gapWalk(ticket, chapter, source);
      if (walk != null) {
        run.follow(walk, chapter.tree);
        await _walk(run, ticket);
      }
    } on Object catch (error) {
      log.w('audit ${source.path}', error);
      if (ticket == _ticket) {
        _set(const AuditFailed('The audit could not finish. Try again.'));
      }
    } finally {
      await run.close();
      // The engine is free again, so another job may start.
      _jobs.release(run);
      if (identical(_holding, run)) _holding = null;
    }
    return null;
  }

  /// The chapter walked as the Replies tab walks it: the same answers
  /// elsewhere in the repertoire, the same floor, the same model. Null when
  /// the run was overtaken on the way.
  Future<GapWalk?> _gapWalk(
    int ticket,
    Chapter chapter,
    ChapterRef source,
  ) async {
    bool overtaken() => _disposed || ticket != _ticket;
    final elsewhere = await _answers.including(
      source,
      chapter.tree,
      chapter.side,
    );
    if (overtaken()) return null;
    return walkGaps(
      tree: chapter.tree,
      side: chapter.side,
      floor: 1 / _settings.value.coverOnceIn,
      shares: _model.sharesAt,
      overtaken: overtaken,
      elsewhere: elsewhere,
    );
  }

  Future<void> _walk(_Run run, int ticket) async {
    final positions = run.positions;
    var checked = 0;
    for (final position in positions) {
      if (_disposed || ticket != _ticket || _stopping || run.lost) break;
      final judged = await _judge(run, position);
      if (_disposed || ticket != _ticket) return;
      if (judged == null) {
        _set(AuditFailed(run.failure ?? 'Stockfish could not start.'));
        return;
      }
      _found = [..._found, ...judged.found]..sort(byReach);
      // A position passed over is not checked: the run ends incomplete,
      // and auditing again asks about it.
      if (judged.passedOver) continue;
      checked++;
      _set(
        AuditRunning(
          checked: checked,
          of: positions.length,
          stopping: _stopping,
        ),
      );
    }
    if (_disposed || ticket != _ticket) return;
    final dropped = run.chessDb?.dropped ?? false;
    log.i(
      'audit: $checked of ${positions.length} positions, '
      '${_found.length} findings'
      '${run.lost ? ', the engine went away' : ''}'
      '${dropped ? ', ChessDB stopped answering' : ''}',
    );
    _set(
      AuditDone(
        checked: checked,
        of: positions.length,
        chessDbDropped: dropped,
      ),
    );
  }

  bool get _stopping => switch (_state) {
    AuditRunning(:final stopping) => stopping,
    _ => false,
  };

  /// The findings at one position; null when the engine could not be
  /// started, which ends the run. A position the engine could not rank, or
  /// one of whose moves it could not score, is passed over with nothing
  /// found — or only what the moves it did score show.
  Future<({List<AuditFinding> found, bool passedOver})?> _judge(
    _Run run,
    AuditPosition position,
  ) async {
    final here = position.fen.position;
    final reach = run.reach[here];
    final lines = await _linesAt(run, position.fen);
    if (lines == null) {
      return run.failure == null
          ? (found: const <AuditFinding>[], passedOver: true)
          : null;
    }
    String sanOf(String uci) =>
        pvMoves(position.fen, [uci]).firstOrNull?.san ?? uci;
    if (position.ours) {
      final scores = await _scoresAfter(run, position, lines);
      if (scores == null) return null;
      return (
        found: weakMoves(
          position,
          lines: lines,
          scoreAfter: scores.scores,
          reach: reach,
          sanOf: sanOf,
        ),
        passedOver: scores.unscored,
      );
    }
    final shares = await _model.sharesAt(position.fen);
    Fen? leadsInto(String uci) =>
        pvMoves(position.fen, [uci]).firstOrNull?.after;
    List<StrongReply> replies(List<ScoredMove> lines, {required bool db}) =>
        strongReplies(
          position,
          lines: lines,
          shares: shares,
          answered: run.answered,
          gaps: run.gaps[here] ?? const {},
          leadsInto: leadsInto,
          sanOf: sanOf,
          reach: reach,
          fromChessDb: db,
        );
    final found = replies(lines, db: false);
    final database = await run.chessDb?.movesAt(position.fen);
    if (database == null) return (found: found, passedOver: false);
    final named = {for (final finding in found) finding.uci};
    return (
      found: [
        ...found,
        for (final reply in replies(database, db: true))
          if (!named.contains(reply.uci)) reply,
      ],
      passedOver: false,
    );
  }

  /// The engine's best [auditLines] at [fen], from the store when a run
  /// has asked before, else from the engine, then kept.
  Future<List<ScoredMove>?> _linesAt(_Run run, Fen fen) async {
    final store = _storeOf();
    final kept = store.lines(
      fen.position,
      depth: fillEvalDepth,
      count: auditLines,
    );
    if (kept != null) return kept;
    final engine = await run.engine(_launch);
    final position = positionOf(fen);
    if (engine == null || position == null) return null;
    final lines = await fixedDepthLines(
      engine,
      position,
      count: auditLines,
      depth: fillEvalDepth,
    );
    if (lines == null) {
      log.w('audit ${fen.value}', 'the engine could not rank the moves');
      return null;
    }
    store.keepLines(
      fen.position,
      lines,
      depth: fillEvalDepth,
      count: auditLines,
    );
    return lines;
  }

  /// The score of each of our chapter moves the lines do not name, from our
  /// side: the negated score of the position after it, through the shared
  /// cache, and whether a move went unscored. Null when the engine could not
  /// be started.
  Future<({Map<String, int> scores, bool unscored})?> _scoresAfter(
    _Run run,
    AuditPosition position,
    List<ScoredMove> lines,
  ) async {
    final named = {for (final line in lines) line.uci};
    final scores = <String, int>{};
    var unscored = false;
    final evaluator = CachedEvaluator(
      _EngineWhenAsked(run, _launch),
      _evalCache(),
      depth: fillEvalDepth,
    );
    for (final move in position.moves) {
      final uci = standardCastling(move.uci, position.fen) ?? move.uci;
      final after = positionOf(move.fen);
      if (named.contains(uci) || after == null) continue;
      if (await evaluationOf(evaluator, after) case Evaluated(:final eval)) {
        scores[uci] = -eval.cp;
      } else {
        unscored = true;
      }
      if (run.failure != null) return null;
    }
    return (scores: scores, unscored: unscored);
  }

  /// Another chapter on the board: the findings were about the last one,
  /// and a run for it stops.
  void _documentChanged() {
    if (_session.source == _audited ||
        (_audited == null && _state is AuditIdle)) {
      return;
    }
    _ticket++;
    _audited = null;
    _found = [];
    _dismissed = {};
    _set(const AuditIdle());
  }

  /// Another job took or gave back the machine: whether an audit may
  /// start has changed.
  void _jobsChanged() {
    if (!_disposed) notifyListeners();
  }

  void _set(AuditState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticket++;
    _session.removeListener(_documentChanged);
    _jobs.removeListener(_jobsChanged);
    if (_holding case final run?) _jobs.release(run);
    super.dispose();
  }
}

/// The run's engine as the cache's fallback: started only when the cache
/// has no score, so an audit the cache answers never starts one.
final class _EngineWhenAsked implements PositionEvaluator {
  const _EngineWhenAsked(this.run, this.launch);

  final _Run run;
  final Future<EngineStart> Function() launch;

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    final engine = await run.engine(launch);
    if (engine == null) {
      return EvaluationUnavailable(run.failure ?? 'no engine');
    }
    return FixedDepthEvaluator(engine, depth: fillEvalDepth).evaluate(position);
  }
}

/// One run's inputs, what the gap walk found, and the engine it started,
/// if it needed one.
final class _Run {
  _Run({required this.positions, required this.chessDb});

  final List<AuditPosition> positions;
  final ChessDbMoves? chessDb;

  /// How often each position is reached, by [Fen.position], as the walk
  /// worked it out; a position reached two ways takes the more often.
  final reach = <String, double>{};

  /// The replies the walk lists as gaps, by the position they are played
  /// from: the Replies tab's, so not the audit's.
  final gaps = <String, Set<String>>{};

  /// The positions the repertoire answers, this chapter or another.
  Set<String> answered = const {};

  /// Takes what [walk], over [tree], found.
  void follow(GapWalk walk, GameTree tree) {
    for (final MapEntry(key: path, value: reached) in walk.reach.entries) {
      final position = tree.fenAt(path).position;
      if (reached > (reach[position] ?? -1)) reach[position] = reached;
    }
    for (final gap in walk.gaps.whereType<MissingReply>()) {
      (gaps[tree.fenAt(gap.at).position] ??= {}).add(gap.uci);
    }
    answered = walk.elsewhere.keys.toSet();
  }

  Engine? _engine;
  Future<Engine?>? _starting;

  /// Why the engine could not be started, once that was tried.
  String? failure;

  /// Whether the engine went away while the run still needed it: every
  /// search after that ends with no lines, so the run stops there.
  bool lost = false;
  bool _closing = false;

  /// Started the first time a position needs it: an audit the store and
  /// the cache answer whole never starts one.
  Future<Engine?> engine(Future<EngineStart> Function() launch) =>
      _starting ??= () async {
        switch (await launch()) {
          case Started(:final engine):
            unawaited(
              engine.exited.then((_) {
                if (!_closing) {
                  log.w('audit', 'the engine went away');
                  lost = true;
                }
              }),
            );
            return _engine = engine;
          case StartFailed(:final reason):
            log.w('start the audit engine', reason);
            failure = reason;
            return null;
        }
      }();

  Future<void> close() async {
    _closing = true;
    chessDb?.close();
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    try {
      await engine.quit();
    } on Object catch (error) {
      log.w('stop the audit engine', error);
    }
  }
}
