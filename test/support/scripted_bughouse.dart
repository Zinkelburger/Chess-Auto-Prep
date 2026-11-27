import 'dart:async';

import 'package:chess_auto_prep/app/environment.dart';
import 'package:chess_auto_prep/chess/bughouse/hypebeast.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/hypebeast_engine.dart';

/// A HypeBeast the test drives. Each search answers [answer] — by default
/// lines of the side to move's first legal moves on the board asked — at
/// once, or when the test calls [release] while [hold] is on. Every search
/// first reports what it will answer at a quarter of its nodes, as the
/// engine reports while it searches, and [report] sends more reports to
/// the searches waiting.
final class ScriptedHypeBeast implements HypeBeast {
  @override
  Map<String, Object?> get provenance => const {
    'engine_name': 'Scripted HypeBeast',
  };
  final asked = <HypeBeastQuestion>[];
  HypeBeastAnswer Function(HypeBeastQuestion question) answer = firstMoves;
  bool hold = false;
  int stops = 0;
  final _held =
      <(HypeBeastQuestion, Completer<HypeBeastAnswer>, HypeBeastReports?)>[];
  final _exited = Completer<EngineExit>();

  @override
  Future<HypeBeastAnswer> search(
    HypeBeastQuestion question, {
    HypeBeastReports? onReport,
  }) {
    asked.add(question);
    if (_exited.isCompleted) {
      return Future.value(
        const HypeBeastFailed('The bughouse engine stopped.'),
      );
    }
    if (onReport != null) {
      scheduleMicrotask(() => _report(question, onReport, 4));
    }
    if (!hold) return Future.value(answer(question));
    final done = Completer<HypeBeastAnswer>();
    _held.add((question, done, onReport));
    return done.future;
  }

  /// Every search waiting reports its lines at its nodes divided by [part].
  void report({int part = 2}) {
    for (final (question, _, onReport) in _held) {
      if (onReport != null) _report(question, onReport, part);
    }
  }

  void _report(
    HypeBeastQuestion question,
    HypeBeastReports onReport,
    int part,
  ) {
    if (answer(question) case HypeBeastSearched(
      :final report,
    ) when report.lines.isNotEmpty) {
      onReport(
        SeatReport(
          lines: [
            for (final line in report.lines)
              SeatLine(
                multipv: line.multipv,
                depth: line.depth,
                seldepth: line.seldepth,
                nodes: line.nodes ~/ part,
                cp: line.cp,
                mate: line.mate,
                pv: line.pv,
              ),
          ],
          nodes: report.nodes ~/ part,
        ),
      );
    }
  }

  /// Answers every search waiting.
  void release() {
    for (final (question, done, _) in _held) {
      done.complete(answer(question));
    }
    _held.clear();
  }

  int get waiting => _held.length;

  @override
  void stop() {
    stops++;
    if (_held.isNotEmpty) release();
  }

  /// The process goes: every search waiting fails.
  void crash() {
    for (final (_, done, _) in _held) {
      done.complete(const HypeBeastFailed('The bughouse engine stopped.'));
    }
    _held.clear();
    if (!_exited.isCompleted) _exited.complete(EngineExit.ended);
  }

  @override
  Future<EngineExit> get exited => _exited.future;

  bool get gone => _exited.isCompleted;

  Future<void> Function()? quitting;

  @override
  Future<void> quit() async {
    await quitting?.call();
    crash();
  }
}

/// The side to move's first three legal moves on the board asked, the first
/// scoring cp −200 from the side to move and each next one 30 worse, over
/// 200 nodes. Alone they are three lines; with the coordinator the first
/// is the main line and all three the moves it compared. The first is the
/// decision; no move, no lines and no decision.
HypeBeastAnswer firstMoves(HypeBeastQuestion question) {
  final moves = question.position.legalMoves(question.board).take(3).toList();
  if (moves.isEmpty) {
    return const HypeBeastSearched(decision: null, report: SeatReport());
  }
  SeatLine line(int i) => SeatLine(
    multipv: i + 1,
    depth: 12,
    seldepth: 16,
    nodes: 200,
    cp: -200 - 30 * i,
    pv: [moves[i].uci],
  );
  return HypeBeastSearched(
    decision: SeatDecision(moves.first.uci),
    report: question.coordination
        ? SeatReport(
            lines: [line(0)],
            coordination: Coordination('kept_main', [
              for (final (i, move) in moves.indexed)
                Candidate(move.uci, l: -200 - 30 * i, s: -200 - 30 * i),
            ]),
            nodes: 200,
          )
        : SeatReport(
            lines: [for (var i = 0; i < moves.length; i++) line(i)],
            nodes: 200,
          ),
  );
}

/// The Bughouse mode's outside world for a window test: the engine
/// bundled, and one scripted engine.
final class ScriptedBughouse {
  /// The engine the last start handed out; a start after it went away
  /// hands out a new one that answers the same way.
  ScriptedHypeBeast engine = ScriptedHypeBeast();
  bool bundled = true;
  String? startFailure;
  int starts = 0;

  BughouseOutside get outside => (
    bundled: () async => bundled,
    launch: () async {
      starts++;
      final failure = startFailure;
      if (failure != null) return HypeBeastStartFailed(failure);
      if (engine.gone) {
        engine = ScriptedHypeBeast()..answer = engine.answer;
      }
      return HypeBeastStarted(engine);
    },
  );
}
