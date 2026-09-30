import 'dart:convert';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/finds_store.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/workspace/fill_states.dart';
import 'package:chess_auto_prep/workspace/finds.dart';
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

/// An engine or a model that gives up on one position stops the run, not
/// the tree: what was built above it is kept, recorded and offered as lines.
void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;
  late int releases;
  late List<String> trees;
  late Finds finds;

  const request = FillRequest(elo: 2200, depthPlies: 3);
  final root = positionOf(kingAndPawn);

  /// White's e4 scored a pawn better than anything else, so the search
  /// keeps it among the moves it goes on with.
  final e4Best = {afterUci(root, 'e2e4').fen: -100};

  setUp(() async {
    fixture = await openSession(chapter);
    analysis = EngineAnalysis(
      fixture.session,
      () async => Started(ScriptedEngine()),
    );
    await analysis.enable();
    releases = 0;
    trees = [];
    final store = FindsStore.inMemory();
    finds = Finds(store: () => store);
    addTearDown(() {
      finds.dispose();
      store.close();
    });
  });

  tearDown(() {
    analysis.dispose();
    fixture.dispose();
  });

  Future<FillGaps> run(
    PositionEvaluator evaluator, {
    OpponentPolicy policy = const ScriptedPolicy({'e8d8': 1}),
    FillRequest asked = request,
  }) async {
    final fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (_) async => FillReady(
        evaluator: evaluator,
        policy: policy,
        release: () async => releases++,
      ),
      keepTree: (ref, tree, {required runId}) async => trees.add(tree),
      finds: finds,
      clock: () => DateTime(2026, 9, 22, 12),
    );
    addTearDown(fill.dispose);
    await fill.start(asked);
    return fill;
  }

  void expectKept(FillGaps fill, String reason) {
    final done = fill.state as FillDone;
    expect(done.complete, isFalse);
    expect(done.nodes, greaterThan(1));
    expect(done.stoppedBy, contains(reason));
    expect((jsonDecode(trees.single) as Map)['build_complete'], isFalse);
    expect(finds.recorded, isA<FindsKept>());
    expect(fill.found!.tree, isA<OurNode>());
    expect(fill.canMakeLines, isTrue);
    expect(releases, 1);
  }

  test('a model that cannot answer stops the run with the reason and keeps '
      'what it had', () async {
    final fill = await run(ScriptedEvaluator(), policy: const AbsentPolicy());
    expectKept(fill, 'opponent model');
  });

  test('a model that fails deeper down keeps the tree above it', () async {
    final fill = await run(
      ScriptedEvaluator(scores: e4Best),
      policy: const _FirstMovePolicy(),
      asked: const FillRequest(elo: 2200, depthPlies: 5),
    );
    expectKept(fill, 'opponent model');
    expect(
      fill.found!.at(const Fen(kingAndPawn), const ['e4', 'Kd8']),
      isA<OurNode>(),
    );
  });

  test('an engine that gives up mid-run stops it with the reason and keeps '
      'what it had', () async {
    final fill = await run(
      ScriptedEvaluator(
        scores: e4Best,
        failAt: afterUci(afterUci(root, 'e2e4'), 'e8d8').fen,
      ),
    );
    expectKept(fill, 'could not score');
  });

  test('an engine that cannot score the board fails the run', () async {
    final fill = await run(ScriptedEvaluator(failAt: root.fen));
    expect(
      fill.state,
      isA<FillFailed>().having(
        (f) => f.reason,
        'reason',
        contains('could not score'),
      ),
    );
    expect(trees, isEmpty);
    expect(finds.recorded, isNull);
    expect(fill.canMakeLines, isFalse);
  });
}

/// A model that knows only Black's first move: every later reply is one it
/// cannot answer.
final class _FirstMovePolicy implements OpponentPolicy {
  const _FirstMovePolicy();

  @override
  Future<PolicyResult> policyFor(Position position) async =>
      position.fullmoves == 1
      ? const PolicyFound(Policy({'e8d8': 1}))
      : const PolicyUnavailable('the scripted model knows only move one');
}
