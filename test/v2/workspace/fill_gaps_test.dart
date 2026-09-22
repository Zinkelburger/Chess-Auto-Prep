import 'dart:async';

import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/sources.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/workspace/fill_gaps.dart';
import 'package:dartchess/dartchess.dart' show Position;
import 'package:flutter_test/flutter_test.dart';

import '../chess/generation/scripted_sources.dart';
import '../support/scripted_engine.dart';
import '../support/scripted_store.dart';
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

/// An engine the test can hold: every question waits until [release].
final class GatedEvaluator implements PositionEvaluator {
  final asked = <String>[];
  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    asked.add(position.fen);
    await _gate.future;
    return const Evaluated(Eval(0));
  }
}

void main() {
  late SessionFixture fixture;
  late ScriptedEngine engine;
  late EngineAnalysis analysis;
  late int releases;

  const request = FillRequest(elo: 2200, depthPlies: 3, onceIn: 50);

  setUp(() async {
    fixture = await openSession(chapter);
    engine = ScriptedEngine();
    analysis = EngineAnalysis(fixture.session, () async => Started(engine));
    await analysis.enable();
    releases = 0;
  });

  tearDown(() {
    analysis.dispose();
    fixture.dispose();
  });

  FillGaps fillWith(
    PositionEvaluator evaluator, {
    OpponentPolicy policy = const ScriptedPolicy({'e8d8': 1}),
    TreeKeeper? keepTree,
  }) {
    final fill = FillGaps(
      session: fixture.session,
      analysis: analysis,
      documents: fixture.store,
      tools: (_) async => FillReady(
        evaluator: evaluator,
        policy: policy,
        release: () async => releases++,
      ),
      keepTree: keepTree,
      clock: () => DateTime(2026, 9, 22, 12),
    );
    addTearDown(fill.dispose);
    return fill;
  }

  ChapterRef draft([String name = 'Main (draft)']) => chapterRef('KID', name);

  String textOf(ChapterRef ref) => switch (fixture.store.documents[ref]) {
    Opened(:final text) => text,
    _ => fail('$ref was not written'),
  };

  test('a run writes a draft chapter beside the one on the board, its lines '
      'carrying their values, and never touches the chapter', () async {
    final trees = <String>[];
    final fill = fillWith(
      ScriptedEvaluator(),
      keepTree: (ref, tree) async => trees.add(tree),
    );
    expect(fill.canStart, isTrue);
    expect(await fill.start(request), isNull);
    expect(fill.state, isA<FillDone>());
    final done = fill.state as FillDone;
    expect(done.name, 'Main (draft)');
    expect(done.lines, 1);
    final text = textOf(draft());
    expect(text, startsWith('// Main (draft)\n// Draft\n// Color: White\n'));
    expect(text, contains('[FEN "$kingAndPawn"]'));
    // Our pinned e4, their one reply, and the move the search chose after
    // it: a line the chapter does not have yet.
    expect(text, contains('1. e4 {[%cumProb 100.0%] [%expectimax'));
    expect(text, contains('Kd8 {[%expectimax'));
    expect(text, contains('2. '));
    expect(fixture.onDisk, chapter, reason: 'the chapter is not written');
    expect(releases, 1);
    expect(trees.single, contains('"format": "opening_tree"'));
    expect(trees.single, contains('"eval_depth": 14'));
  });

  test('the chapter\'s own moves are pins: the search never plays another '
      'move where the chapter already has one', () async {
    final evaluator = ScriptedEvaluator();
    final fill = fillWith(evaluator);
    await fill.start(request);
    final root = positionOf(kingAndPawn);
    expect(evaluator.asked, contains(afterUci(root, 'e2e4').fen));
    expect(evaluator.asked, isNot(contains(afterUci(root, 'e2e3').fen)));
  });

  test('the engine pane is paused for the run and follows the board again '
      'after it', () async {
    final gate = GatedEvaluator();
    final fill = fillWith(gate);
    final run = fill.start(request);
    await pumpEventQueue();
    expect(analysis.state, isA<EnginePaused>());
    expect(analysis.paused, isTrue);
    expect(engine.current.stopped, isTrue, reason: 'the pane stopped looking');
    expect(fill.state, isA<FillRunning>());
    gate.release();
    await run;
    expect(analysis.paused, isFalse);
    expect(engine.searches.last.stopped, isFalse, reason: 'looking again');
  });

  test('a second run is refused while one is running', () async {
    final gate = GatedEvaluator();
    final fill = fillWith(gate);
    final run = fill.start(request);
    await pumpEventQueue();
    expect(fill.canStart, isFalse);
    expect(await fill.start(request), 'A fill is already running.');
    gate.release();
    await run;
  });

  test(
    'cancel stops the run, hands the engine back and writes nothing',
    () async {
      final gate = GatedEvaluator();
      final fill = fillWith(gate);
      final run = fill.start(request);
      await pumpEventQueue();
      fill.cancel();
      expect((fill.state as FillRunning).cancelling, isTrue);
      expect(releases, 1, reason: 'the engine is let go at once');
      gate.release();
      await run;
      expect(fill.state, isA<FillIdle>());
      expect(fixture.store.documents.keys.map((r) => r.path), [
        fixture.ref.path,
      ]);
      expect(analysis.paused, isFalse);
    },
  );

  test(
    'no engine is a failure named on the card, and the pane resumes',
    () async {
      final fill = FillGaps(
        session: fixture.session,
        analysis: analysis,
        documents: fixture.store,
        tools: (_) async => const FillUnavailable('Stockfish is not installed'),
      );
      addTearDown(fill.dispose);
      await fill.start(request);
      expect(
        fill.state,
        isA<FillFailed>().having(
          (f) => f.reason,
          'reason',
          'Stockfish is not installed',
        ),
      );
      expect(analysis.paused, isFalse);
      fill.dismiss();
      expect(fill.state, isA<FillIdle>());
    },
  );

  test('an engine that finishes starting after dispose is still handed '
      'back', () async {
    final starting = Completer<FillToolsResult>();
    final fill = FillGaps(
      session: fixture.session,
      analysis: analysis,
      documents: fixture.store,
      tools: (_) => starting.future,
    );
    final run = fill.start(request);
    await pumpEventQueue();
    fill.dispose();
    starting.complete(
      FillReady(
        evaluator: ScriptedEvaluator(),
        policy: const ScriptedPolicy({'e8d8': 1}),
        release: () async => releases++,
      ),
    );
    await run;
    expect(releases, 1);
  });

  test('a model that cannot answer stops the run with the reason', () async {
    final fill = fillWith(ScriptedEvaluator(), policy: const AbsentPolicy());
    await fill.start(request);
    expect(
      fill.state,
      isA<FillFailed>().having(
        (f) => f.reason,
        'reason',
        contains('opponent model'),
      ),
    );
    expect(releases, 1);
  });

  test('an engine that gives up mid-run stops it with the reason', () async {
    final root = positionOf(kingAndPawn);
    final fill = fillWith(
      ScriptedEvaluator(failAt: afterUci(root, 'e2e4').fen),
    );
    await fill.start(request);
    expect(
      fill.state,
      isA<FillFailed>().having(
        (f) => f.reason,
        'reason',
        contains('could not score'),
      ),
    );
  });

  test('a draft name already taken gets the next number', () async {
    fixture.store.documents[draft()] = Opened('old', scriptedRevision('old'));
    final fill = fillWith(ScriptedEvaluator());
    await fill.start(request);
    expect((fill.state as FillDone).name, 'Main (draft 2)');
    expect(textOf(draft('Main (draft 2)')), contains('// Draft'));
    expect(textOf(draft()), 'old');
  });

  test(
    'a search that proposes nothing new is a failure, not an empty draft',
    () async {
      // Horizon one: only our pinned e4, which the chapter already plays.
      final fill = fillWith(ScriptedEvaluator());
      await fill.start(const FillRequest(elo: 2200, depthPlies: 1, onceIn: 50));
      expect(
        fill.state,
        isA<FillFailed>().having(
          (f) => f.reason,
          'reason',
          contains('already'),
        ),
      );
      expect(fixture.store.documents.keys, hasLength(1));
    },
  );

  test(
    'a store that refuses the draft is a failure named on the card',
    () async {
      fixture.store.creates.add(const IoFailure('disk full'));
      final fill = fillWith(ScriptedEvaluator());
      await fill.start(request);
      expect(
        fill.state,
        isA<FillFailed>().having(
          (f) => f.reason,
          'reason',
          contains('disk full'),
        ),
      );
    },
  );

  test('a document this app may not write cannot be filled', () async {
    final readOnly = await openSession(chapter, readOnly: 'outside Documents');
    addTearDown(readOnly.dispose);
    final fill = FillGaps(
      session: readOnly.session,
      analysis: analysis,
      documents: readOnly.store,
      tools: (_) async => const FillUnavailable('never asked'),
    );
    addTearDown(fill.dispose);
    expect(fill.canStart, isFalse);
    expect(await fill.start(request), 'outside Documents');
  });

  test('progress is the nodes and the depth of the run so far', () async {
    final fill = fillWith(ScriptedEvaluator());
    final seen = <FillRunning>[];
    fill.addListener(() {
      if (fill.state case final FillRunning running) seen.add(running);
    });
    await fill.start(request);
    expect(seen.first.of, 3);
    expect(seen.last.depth, 3);
    expect(seen.last.nodes, greaterThan(1));
  });

  test('the fill starts from the board, not the chapter root', () async {
    fixture.session.forward();
    fixture.session.forward();
    final evaluator = ScriptedEvaluator();
    final fill = fillWith(evaluator);
    await fill.start(const FillRequest(elo: 2200, depthPlies: 1, onceIn: 50));
    final board = positionOf(fixture.session.fen.value);
    expect(evaluator.asked.first, board.fen);
    // The line is written from the chapter's root through the moves to the
    // board, so it can be dropped into the chapter.
    expect(textOf(draft()), contains('1. e4 Kd8 2. '));
  });
}
