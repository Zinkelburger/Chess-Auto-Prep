import 'dart:convert';

import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/generation_trees.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/workspace/fill_states.dart';
import 'package:dartchess/dartchess.dart' show Side;
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

/// A model with an answer for either side: e4 three games in four for
/// White, Kd8 always for Black.
const bothSides = ScriptedPolicy({'e2e4': 3, 'e2e3': 1, 'e8d8': 1});

/// One press searches for both sides: the board's, which becomes lines and
/// is what the run reports, and the other, for its values alone.
void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;
  late EngineJobs jobs;

  const request = FillRequest(elo: 2200, depthPlies: 2);

  setUp(() async {
    fixture = await openSession(chapter);
    analysis = EngineAnalysis(
      fixture.session,
      () async => Started(ScriptedEngine()),
    );
    jobs = EngineJobs(analysis);
    await analysis.enable();
  });

  tearDown(() {
    analysis.dispose();
    fixture.dispose();
  });

  FillGaps fillWith(
    PositionEvaluator evaluator, {
    OpponentPolicy policy = bothSides,
    TreeKeeper? keepTree,
    TreeLoader? loadTree,
  }) {
    final fill = FillGaps(
      session: fixture.session,
      jobs: jobs,
      documents: fixture.store,
      tools: (_) async =>
          FillReady(evaluator: evaluator, policy: policy, release: () async {}),
      keepTree: keepTree,
      loadTree: loadTree,
      clock: () => DateTime(2026, 9, 22, 12),
    );
    addTearDown(fill.dispose);
    return fill;
  }

  Side sideOf(String tree) =>
      ((jsonDecode(tree) as Map)['config'] as Map)['play_as_white'] == true
      ? Side.white
      : Side.black;

  test('the board is searched for both sides, and each tree answers for '
      'its own', () async {
    // e4 scores a pawn better than anything else, so the shortlist keeps it.
    final fill = fillWith(
      ScriptedEvaluator(
        scores: {afterUci(positionOf(kingAndPawn), 'e2e4').fen: -100},
      ),
    );
    expect(await fill.start(request), isNull);
    expect(fill.state, isA<FillDone>());
    expect(fill.found!.side, Side.white, reason: 'the board\'s side');
    // White to move: White's search chooses, Black's expects.
    expect(fill.nodeAtBoard(), isA<OurNode>());
    final expected = fill.nodeAtBoard(side: Side.black) as OpponentNode;
    expect(
      {for (final r in expected.replies) r.move.san: r.probability},
      {'e4': 0.75, 'e3': 0.25},
    );
    // One move on, the roles swap.
    fixture.session.forward();
    expect(fill.nodeAtBoard(), isA<OpponentNode>());
    expect(fill.nodeAtBoard(side: Side.black), isA<OurNode>());
  });

  test('a position both sides reach is scored once', () async {
    final evaluator = ScriptedEvaluator();
    final fill = fillWith(evaluator);
    await fill.start(request);
    expect(evaluator.asked.toSet().length, evaluator.asked.length);
  });

  test('the run reports the board\'s side alone', () async {
    final alone = fillWith(
      ScriptedEvaluator(),
      policy: const ScriptedPolicy({'e8d8': 1}),
    );
    await alone.start(request);
    final fill = fillWith(ScriptedEvaluator());
    await fill.start(request);
    expect(
      (fill.state as FillDone).nodes,
      (alone.state as FillDone).nodes,
      reason: 'the other side\'s positions are not counted',
    );
  });

  test(
    'a model with no answer for the other side leaves the run whole',
    () async {
      final trees = <String>[];
      final fill = fillWith(
        ScriptedEvaluator(),
        policy: const ScriptedPolicy({'e8d8': 1}),
        keepTree: (_, tree, {required runId}) async => trees.add(tree),
      );
      expect(await fill.start(request), isNull);
      final done = fill.state as FillDone;
      expect(done.complete, isTrue);
      expect(done.stoppedBy, isNull);
      expect(fill.nodeAtBoard(), isA<OurNode>());
      expect(fill.nodeAtBoard(side: Side.black), isNull);
      expect(trees.map(sideOf), [Side.white], reason: 'nothing to keep');
    },
  );

  test('both trees are kept beside the chapter, and a new owner goes on '
      'from both', () async {
    final trees = <String>[];
    final first = fillWith(
      ScriptedEvaluator(),
      keepTree: (_, tree, {required runId}) async => trees.add(tree),
    );
    await first.start(const FillRequest(elo: 2200, depthPlies: 1));
    expect(trees.map(sideOf).toSet(), {Side.white, Side.black});

    final evaluator = ScriptedEvaluator();
    final restarted = fillWith(
      evaluator,
      // Newest first, as the store hands them out.
      loadTree: (_, _) => Stream.fromIterable(trees.reversed),
    );
    expect(await restarted.resume(request), isNull);
    expect(
      evaluator.asked,
      isNot(contains(kingAndPawn)),
      reason: 'neither side scores the board again',
    );
    final expected = restarted.nodeAtBoard(side: Side.black) as OpponentNode;
    expect(
      expected.replies.first.child,
      isA<OurNode>(),
      reason: 'searched a move deeper than it was saved',
    );
  });

  test('the mainline book is built for the board\'s side alone', () async {
    var asked = 0;
    final fill = FillGaps(
      session: fixture.session,
      jobs: jobs,
      documents: fixture.store,
      tools: (_) async {
        asked++;
        return const FillUnavailable('no book in this test');
      },
      clock: () => DateTime(2026, 9, 22, 12),
    );
    addTearDown(fill.dispose);
    await fill.start(
      const FillRequest(elo: 2200, method: SearchMethod.mainline),
    );
    expect(asked, 1);
    expect(fill.nodeAtBoard(side: Side.black), isNull);
  });

  test('stopping stops both sides and keeps what each has', () async {
    final fill = fillWith(ScriptedEvaluator());
    fill.addListener(() {
      if (fill.state case FillRunning(:final depth) when depth >= 2) {
        fill.finishLevel();
      }
    });
    await fill.start(const FillRequest(elo: 2200));
    final done = fill.state as FillDone;
    expect(done.complete, isFalse);
    expect(fill.nodeAtBoard(), isA<OurNode>());
    expect(fill.nodeAtBoard(side: Side.black), isA<OpponentNode>());
    expect(fill.canStart, isTrue, reason: 'the engine was handed back');
  });

  test('flipping the board shows the same run from the other side', () async {
    final fill = fillWith(ScriptedEvaluator());
    await fill.start(request);
    fixture.session.flip();
    expect(fixture.session.orientation, Side.black);
    expect(
      fill.nodeAtBoard(),
      isA<OpponentNode>(),
      reason: 'Black\'s tree is the board\'s now',
    );
    expect(fill.nodeAtBoard(side: Side.white), isA<OurNode>());
  });
}
