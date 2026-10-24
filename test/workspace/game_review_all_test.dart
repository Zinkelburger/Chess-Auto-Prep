import 'dart:async';

import 'package:chess_auto_prep/chess/pgn/game_review.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/game_review.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_engine.dart';
import '../support/session_fixture.dart';

/// Three chapters; the second was reviewed before.
const _study = '''
[Event "Endgames: One"]
[Result "*"]
[ChapterName "One"]

1. e4 e5 2. Nf3 *

[Event "Endgames: Two"]
[Result "*"]
[ChapterName "Two"]

{[%eval 0.20] [%cap_review_eval]} 1. d4 d5 *

[Event "Endgames: Three"]
[Result "*"]
[ChapterName "Three"]

1. c4 *
''';

/// Every game of the file reviewed in turn while the user reads on.
void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;
  late EngineJobs jobs;
  late ScriptedEngine engine;
  late GameReview review;

  setUp(() async {
    fixture = await openSession(_study);
    await fixture.session.open(fixture.ref, game: 0);
    engine = ScriptedEngine();
    analysis = EngineAnalysis(
      fixture.session,
      () async => const StartFailed('off'),
    );
    jobs = EngineJobs(analysis);
    review = GameReview(
      session: fixture.session,
      jobs: jobs,
      launch: () async => Started(engine),
    );
  });
  tearDown(() {
    review.dispose();
    jobs.dispose();
    analysis.dispose();
    fixture.dispose();
  });

  /// Answers every search as it comes until [running] is over, calling
  /// [onSearch] with each search's number first.
  Future<void> answer(
    Future<void> running, {
    void Function(int search)? onSearch,
  }) async {
    var done = false;
    unawaited(running.whenComplete(() => done = true));
    var answered = 0;
    while (!done) {
      await pumpEventQueue();
      while (answered < engine.searches.length) {
        onSearch?.call(answered);
        final search = engine.searches[answered++];
        search.emit(line(depth: 14, score: const Centipawns(20), pv: []));
        search.end();
      }
    }
  }

  List<GameTree> trees() => [
    for (final line in fixture.session.chapter!.lines) line.tree!,
  ];

  test('each game is written as it finishes, a reviewed one passed over, '
      'and the game on the board stays', () async {
    expect(review.canReviewAll, isTrue);
    await answer(review.startAll());
    expect(review.problem, isNull);
    expect(review.running, isFalse);
    expect(review.batch, isNull);
    // One: four positions; Two passed over; Three: two positions.
    expect(engine.searches, hasLength(6));
    expect(trees().map(hasReview), [true, true, true]);
    expect(fixture.onDisk, contains('[%eval 0.20] [%cap_review_eval]'));
    expect(fixture.session.game, 0);
    expect(engine.quitCalled, isTrue);
  });

  test('a game the user changed while it was reviewed is left as they '
      'made it', () async {
    await answer(
      review.startAll(),
      onSearch: (search) {
        // While One is reviewed, a move is added to its main line.
        if (search != 1) return;
        fixture.session.cursor.goTo(NodePath.of([0, 0, 0]));
        fixture.session.playMove('b8c6');
      },
    );
    expect(review.problem, isNull);
    final [one, _, three] = trees();
    expect(hasReview(one), isFalse);
    expect(hasReview(three), isTrue);
  });

  test('another file stops it', () async {
    final running = review.startAll();
    await pumpEventQueue();
    expect(review.batch?.game, 0);
    fixture.session.closed();
    await pumpEventQueue();
    engine.current.end();
    await running;
    expect(review.running, isFalse);
    expect(engine.searches, hasLength(1));
  });

  test('a file of one game has no review of every game', () async {
    final single = await openSession('[Event "One"]\n\n1. e4 *');
    addTearDown(single.dispose);
    await single.session.open(single.ref, game: 0);
    final alone = GameReview(
      session: single.session,
      jobs: jobs,
      launch: () async => Started(engine),
    );
    addTearDown(alone.dispose);
    expect(alone.canReviewAll, isFalse);
  });
}
