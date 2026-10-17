import 'dart:async';

import 'package:chess_auto_prep/app/environment.dart';
import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/hivemind_engine.dart';

/// A Hivemind the test drives. Each search answers [answer] — by default a
/// few lines of the searched team's first legal moves — at once, or when
/// the test calls [release] while [hold] is on.
final class ScriptedHivemind implements Hivemind {
  @override
  Map<String, Object?> get provenance => const {
    'engine_name': 'Scripted Hivemind',
  };
  final asked = <HivemindQuestion>[];
  HivemindAnswer Function(HivemindQuestion question) answer = firstMoves;
  bool hold = false;
  int stops = 0;
  final _held = <(HivemindQuestion, Completer<HivemindAnswer>)>[];
  final _exited = Completer<EngineExit>();

  @override
  Future<HivemindAnswer> search(HivemindQuestion question) {
    asked.add(question);
    if (_exited.isCompleted) {
      return Future.value(const HivemindFailed('The bughouse engine stopped.'));
    }
    if (!hold) return Future.value(answer(question));
    final done = Completer<HivemindAnswer>();
    _held.add((question, done));
    return done.future;
  }

  /// Answers every search waiting.
  void release() {
    for (final (question, done) in _held) {
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
    for (final (_, done) in _held) {
      done.complete(const HivemindFailed('The bughouse engine stopped.'));
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

/// Up to three lines, one per legal move of the searched team on the first
/// board it is on move, the first scoring cp −200 and each next one 30
/// worse; no move, no lines.
HivemindAnswer firstMoves(HivemindQuestion question) {
  final position = question.position;
  final board = BoardNumber.values
      .where((b) => position.mover(b).team == question.team)
      .firstOrNull;
  if (board == null) return const HivemindSearched(best: null, lines: []);
  final moves = position.legalMoves(board).take(3).toList();
  JointMove joint(String uci) =>
      board == BoardNumber.one ? JointMove(uci, null) : JointMove(null, uci);
  final lines = [
    for (final (i, move) in moves.indexed)
      JointLine(
        rank: i + 1,
        cp: -200 - 30 * i,
        nodes: 200,
        pv: [joint(move.uci)],
      ),
  ];
  return HivemindSearched(best: lines.firstOrNull?.pv.first, lines: lines);
}

/// The Bughouse mode's outside world for a window test: the engine
/// bundled, and one scripted engine.
final class ScriptedBughouse {
  /// The engine the last start handed out; a start after it went away
  /// hands out a new one that answers the same way.
  ScriptedHivemind engine = ScriptedHivemind();
  bool bundled = true;
  String? startFailure;
  int starts = 0;

  BughouseOutside get outside => (
    bundled: () async => bundled,
    launch: ({required cores}) async {
      starts++;
      final failure = startFailure;
      if (failure != null) return HivemindStartFailed(failure);
      if (engine.gone) {
        engine = ScriptedHivemind()..answer = engine.answer;
      }
      return HivemindStarted(engine);
    },
  );
}
