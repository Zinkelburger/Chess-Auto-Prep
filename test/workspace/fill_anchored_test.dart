import 'dart:async';

import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/generation_trees.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/search/fill_gaps.dart';
import 'package:chess_auto_prep/workspace/search/fill_states.dart';
import 'package:dartchess/dartchess.dart' show Position;
import 'package:flutter_test/flutter_test.dart';

import '../chess/generation/scripted_sources.dart';
import '../support/scripted_engine.dart';
import '../support/session_fixture.dart';

/// White king and pawn against a bare king: few moves, so a run is small.
const kingAndPawn = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

const chapter =
    '''
// Color: White

[Event "Main"]
[Result "*"]
[FEN "$kingAndPawn"]
[SetUp "1"]

1. e4 Kd8 *
''';

/// An engine the test holds: every question waits until [open].
final class _Gated implements PositionEvaluator {
  final asked = <String>[];
  final _gate = Completer<void>();

  void open() => _gate.complete();

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    asked.add(position.fen);
    await _gate.future;
    return const Evaluated(Eval(0));
  }
}

/// A run goes from searching to saving to over, and stays where it was
/// started while the board moves: what each stop and each move does on the
/// way.
void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;
  late EngineJobs jobs;
  late int releases;

  /// Every run's engine, in the order the runs asked for one.
  late List<PositionEvaluator> engines;

  const request = FillRequest(elo: 2200, depthPlies: 2);

  setUp(() async {
    fixture = await openSession(chapter);
    analysis = EngineAnalysis(
      fixture.session,
      () async => Started(ScriptedEngine()),
    );
    jobs = EngineJobs(analysis);
    await analysis.enable();
    releases = 0;
    engines = [];
  });

  tearDown(() {
    analysis.dispose();
    fixture.dispose();
  });

  FillGaps fillWith(
    PositionEvaluator Function() engine, {
    TreeKeeper? keepTree,
    FillToolsFactory? tools,
  }) {
    final fill = FillGaps(
      session: fixture.session,
      jobs: jobs,
      documents: fixture.store,
      tools:
          tools ??
          (_) async => FillReady(
            evaluator: (engines..add(engine())).last,
            policy: const ScriptedPolicy({'e8d8': 1}),
            release: () async => releases++,
          ),
      keepTree: keepTree,
      clock: () => DateTime(2026, 10, 29, 12),
    );
    addTearDown(fill.dispose);
    return fill;
  }

  Future<void> until(bool Function() done) async {
    while (!done()) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('a finished search still saving its tree stays put while the board '
      'moves, and starts again only when asked', () async {
    final gate = Completer<void>();
    final fill = fillWith(
      ScriptedEvaluator.new,
      keepTree: (_, _, {required runId}) => gate.future,
    );
    final run = fill.start(const FillRequest(elo: 2200, depthPlies: 1));
    await until(() => fill.state is FillDone);
    final found = fill.found;
    expect(fill.running, isFalse);
    expect(fill.canStart, isFalse, reason: 'its tree is still being saved');
    expect(
      await fill.start(request),
      'A search is already running.',
      reason: 'the run is not over until its tree is saved',
    );

    fixture.session.playMove('e2e4');
    await pumpEventQueue();
    expect(engines, hasLength(1));
    expect(fill.state, isA<FillDone>());
    expect(fill.found, same(found));

    gate.complete();
    await run;
    expect(fill.canStart, isTrue);
    fixture.session.cursor.back();
    await pumpEventQueue();
    expect(engines, hasLength(1), reason: 'browsing never starts a search');
    expect(releases, 1);
  });

  test('cancelled while the engine starts, the engine is handed back once '
      'it is up and the search is idle', () async {
    final starting = Completer<FillToolsResult>();
    final fill = fillWith(ScriptedEvaluator.new, tools: (_) => starting.future);
    final run = fill.start(request);
    await pumpEventQueue();
    expect(analysis.paused, isTrue);
    fill.cancel();
    expect((fill.state as FillRunning).cancelling, isTrue);
    expect(releases, 0, reason: 'there is no engine to hand back yet');
    starting.complete(
      FillReady(
        evaluator: ScriptedEvaluator(),
        policy: const ScriptedPolicy({'e8d8': 1}),
        release: () async => releases++,
      ),
    );
    await run;
    expect(releases, 1);
    expect(fill.state, isA<FillIdle>());
    expect(fill.canStart, isTrue);
    expect(analysis.paused, isFalse);
  });

  test('disposed while the engine starts, the engine is handed back once '
      'and the machine is free', () async {
    final starting = Completer<FillToolsResult>();
    final fill = FillGaps(
      session: fixture.session,
      jobs: jobs,
      documents: fixture.store,
      tools: (_) => starting.future,
    );
    final run = fill.start(request);
    await pumpEventQueue();
    fill.dispose();
    expect(releases, 0);
    starting.complete(
      FillReady(
        evaluator: ScriptedEvaluator(),
        policy: const ScriptedPolicy({'e8d8': 1}),
        release: () async => releases++,
      ),
    );
    await run;
    await pumpEventQueue();
    expect(releases, 1);
    expect(analysis.paused, isFalse);
  });

  test('a running search stays where it was started while the board moves, '
      'and its tree is read at the board', () async {
    final fill = fillWith(_Gated.new);
    final run = fill.start(request);
    await pumpEventQueue();
    expect(fill.running, isTrue);

    fixture.session.playMove('e2e4');
    await pumpEventQueue();
    expect(fill.running, isTrue, reason: 'a move on the board stops nothing');
    expect((fill.state as FillRunning).stopping, isFalse);
    expect(engines, hasLength(1), reason: 'and starts no second search');

    (engines.single as _Gated).open();
    await run;
    expect(fill.state, isA<FillDone>());
    expect(
      fill.found!.target.sans,
      isEmpty,
      reason: 'the run is still the one started at the first board',
    );
    expect(
      fill.nodeAtBoard()?.fen.value,
      afterUci(positionOf(kingAndPawn), 'e2e4').fen,
      reason: 'the table reads the tree at the position browsed to',
    );
    expect(releases, 1);
  });

  test('a running search stops and keeps what it has when the board is '
      'turned to the other side', () async {
    final fill = fillWith(_Gated.new);
    final run = fill.start(request);
    await pumpEventQueue();
    fixture.session.flip();
    expect((fill.state as FillRunning).finishing, isTrue);
    (engines.single as _Gated).open();
    await run;
    expect(fill.state, isA<FillDone>());
    expect(fill.found, isNotNull);
    expect(engines, hasLength(1));
  });

  test('after a cancel the board moves freely and nothing starts', () async {
    final fill = fillWith(_Gated.new);
    final first = fill.start(request);
    await pumpEventQueue();
    fill.cancel();
    fixture.session.playMove('e2e4');
    fixture.session.cursor.back();
    (engines.single as _Gated).open();
    await first;
    await pumpEventQueue();
    expect(fill.state, isA<FillIdle>());
    expect(engines, hasLength(1));
    expect(releases, 1);
  });
}
