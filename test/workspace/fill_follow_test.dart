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

/// A run goes from searching to saving to over, and only a run still
/// searching follows the board: what each stop and each move does on the
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

    expect(await fill.followMove('e2e4'), isNull);
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

  test('after a cancel the board moves freely, and a search started again '
      'follows it', () async {
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
    expect(engines, hasLength(1), reason: 'a cancelled search follows nothing');
    expect(releases, 1);

    final second = fill.start(request);
    await pumpEventQueue();
    expect(fill.running, isTrue);
    final following = fill.followMove('e2e4');
    (engines[1] as _Gated).open();
    await second;
    await until(() => engines.length == 3);
    expect(fill.running, isTrue);
    expect(
      (engines[2] as _Gated).asked.first,
      afterUci(positionOf(kingAndPawn), 'e2e4').fen,
      reason: 'the new run starts at the board it followed',
    );
    fill.cancel();
    (engines[2] as _Gated).open();
    expect(await following, isNull);
    expect(fill.state, isA<FillIdle>());
    expect(releases, 3);
  });

  test('a stop asked while the search waits to follow the board starts '
      'nothing', () async {
    final gate = Completer<void>();
    var saves = 0;
    final fill = fillWith(
      ScriptedEvaluator.new,
      keepTree: (_, _, {required runId}) async {
        if (++saves == 1) await gate.future;
      },
    );
    Future<String?>? following;
    void follow() {
      if (fill.running && fill.found != null && following == null) {
        following = Future.value();
        following = fill.followMove('e2e4');
      }
    }

    fill.addListener(follow);
    final run = fill.start(request);
    await until(() => saves > 0);
    fill.removeListener(follow);
    expect(fill.state, isA<FillDone>());
    expect(fill.canStart, isFalse);
    fill.finish();
    gate.complete();
    await run;
    expect(await following, isNull);
    await pumpEventQueue();
    expect(engines, hasLength(1));
    expect(fill.running, isFalse);
    expect(fill.canStart, isTrue);
  });
}
