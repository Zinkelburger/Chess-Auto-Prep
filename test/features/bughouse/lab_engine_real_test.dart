import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/hypebeast_engine.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/lab_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The mode's engine owner over the real HypeBeast named by `HYPEBEAST_BIN`
/// and `HYPEBEAST_NET`, as `test/engines/hypebeast_real_test.dart` runs it.
/// Without both it does not run.
final _env = Platform.environment;
final _bin = _env['HYPEBEAST_BIN'] ?? '';
final _net = _env['HYPEBEAST_NET'] ?? '';
final Object _skip = _bin.isEmpty || _net.isEmpty
    ? 'set HYPEBEAST_BIN and HYPEBEAST_NET to run the real engine'
    : false;

/// A real engine whose every answer the test keeps.
final class _Kept implements HypeBeast {
  _Kept(this._engine);

  final HypeBeast _engine;
  final answers = <(HypeBeastQuestion, HypeBeastAnswer)>[];

  @override
  Map<String, Object?> get provenance => _engine.provenance;

  @override
  bool get clocked => _engine.clocked;

  @override
  Future<HypeBeastAnswer> search(
    HypeBeastQuestion question, {
    HypeBeastReports? onReport,
  }) async {
    final answer = await _engine.search(question, onReport: onReport);
    answers.add((question, answer));
    return answer;
  }

  @override
  void stop() => _engine.stop();

  @override
  Future<EngineExit> get exited => _engine.exited;

  @override
  Future<void> quit() => _engine.quit();
}

void main() {
  test(
    'a game with all four clocks: the engine sits on board 1 and says why; '
    'the same table without clocks is searched by a fresh process, which '
    'knows no clocks',
    () async {
      final engines = EngineSupervisor();
      addTearDown(engines.dispose);
      final started = <_Kept>[];
      final lab = BughouseLab();
      addTearDown(lab.dispose);
      final engine = LabEngine(
        lab: lab,
        cores: 3,
        searchTime: const Duration(seconds: 3),
        startEngine: () async {
          final start = await engines.startHypeBeast((
            executable: p.absolute(_bin),
            net: p.absolute(_net),
            directory: p.dirname(p.absolute(_net)),
          ));
          if (start case HypeBeastStarted(:final engine)) {
            final kept = _Kept(engine);
            started.add(kept);
            return HypeBeastStarted(kept);
          }
          return start;
        },
      );
      addTearDown(engine.dispose);

      Future<LinesOn> rested() async {
        final done = Completer<void>();
        void check() {
          if (engine.lines case LinesOn(
            thinking: false,
            :final position,
          ) when position == lab.position && !done.isCompleted) {
            done.complete();
          }
          if (engine.lines case LinesStopped(:final reason)) fail(reason);
        }

        engine.addListener(check);
        check();
        await done.future.timeout(const Duration(seconds: 60));
        engine.removeListener(check);
        return engine.lines as LinesOn;
      }

      lab.pasteMoves(
        File('test/fixtures/bughouse/hypebeast_hold.bpgn').readAsStringSync(),
      );
      expect(lab.boards, LabBoards.two);
      engine
        ..open()
        ..toggle();
      var lines = await rested();
      final sit = lines.rows[BoardNumber.one]!.first;
      expect(sit.move, isNull);
      expect(sit.reason, 'hold_mated');
      // A is mated in one whatever it plays: C + D's mate.
      expect(lines.score.mate, isNegative);
      expect(started, hasLength(2));
      expect(started.every((e) => e.clocked), isTrue);

      // The same table set up afresh has no game, so no clocks.
      lab.loadDualFen(lab.position.dualFen);
      expect(lab.boards, LabBoards.two);
      lines = await rested();
      expect(started, hasLength(4), reason: 'both processes replaced');
      for (final kept in started.skip(2)) {
        final (question, answer) = kept.answers.single;
        expect(question.clocks, isNull);
        final searched = answer as HypeBeastSearched;
        expect(searched.report.summary['wait'], 'skip_no_clocks');
      }
      expect(lines.rows[BoardNumber.one]!.first.move, isNotNull);
    },
    skip: _skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
