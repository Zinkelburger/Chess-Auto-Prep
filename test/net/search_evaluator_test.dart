import 'dart:async';

import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/evaluation_source.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/net/remote_queue.dart';
import 'package:chess_auto_prep/net/search_evaluator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../chess/generation/search_harness.dart';

void main() {
  test('cloud scores use White perspective once, reject shallow data', () {
    const body = '{"depth":20,"pvs":[{"cp":100}]}';
    expect(lichessScore(body, whiteToMove: false, minDepth: 14)?.cp, -100);
    expect(lichessScore(body, whiteToMove: true, minDepth: 21), isNull);
    expect(
      lichessScore(
        '{"depth":20,"pvs":[{"mate":3}]}',
        whiteToMove: false,
        minDepth: 14,
      )?.cp,
      -9994,
    );
    expect(chessDbScore('eval:-29997')?.cp, -9997);
    expect(chessDbScore('unknown'), isNull);
  });

  test('cloud evaluation carries its reported depth', () async {
    final evaluator = SearchEvaluator(
      source: EvaluationSource.lichess,
      fallback: ScriptedEvaluator(),
      minDepth: 14,
      run: RemoteQueue(
        MockClient(
          (_) async => http.Response('{"depth":22,"pvs":[{"cp":30}]}', 200),
        ),
      ).run(),
    );
    addTearDown(evaluator.close);
    final answer =
        await evaluator.evaluate(positionOf(kingAndPawn)) as Evaluated;
    expect(answer.depth, 22);
  });

  test(
    'a cloud answer that is not JSON falls back to the local engine',
    () async {
      final local = ScriptedEvaluator(fallback: 42);
      final evaluator = SearchEvaluator(
        source: EvaluationSource.lichess,
        fallback: local,
        minDepth: 14,
        run: RemoteQueue(
          MockClient((_) async => http.Response('<html>blocked</html>', 200)),
        ).run(),
      );
      addTearDown(evaluator.close);
      final answer = await evaluator.evaluate(positionOf(kingAndPawn));
      expect((answer as Evaluated).eval.cp, 42);
      expect(local.asked, hasLength(1));
    },
  );

  test(
    'a rate limit stops remote requests for the run and falls back',
    () async {
      var calls = 0;
      final local = ScriptedEvaluator(fallback: 42);
      final evaluator = SearchEvaluator(
        source: EvaluationSource.lichess,
        fallback: local,
        minDepth: 14,
        run: RemoteQueue(
          MockClient((_) async {
            calls++;
            return http.Response('', 429);
          }),
        ).run(),
      );
      addTearDown(evaluator.close);
      final first =
          await evaluator.evaluate(positionOf(kingAndPawn)) as Evaluated;
      final second = await evaluator.evaluate(positionOf(afterE4)) as Evaluated;
      expect(first.eval.cp, 42);
      expect(second.eval.cp, 42);
      expect(calls, 1);
      expect(local.asked, hasLength(2));
    },
  );

  test(
    'remote hits are reused within a run and never passed to local engine',
    () async {
      final local = ScriptedEvaluator();
      var calls = 0;
      final evaluator = SearchEvaluator(
        source: EvaluationSource.chessDb,
        fallback: local,
        minDepth: 14,
        run: RemoteQueue(
          MockClient((uri) async {
            calls++;
            expect(uri.url.queryParameters['learn'], '0');
            return http.Response('eval:-80', 200);
          }),
        ).run(),
      );
      addTearDown(evaluator.close);
      final position = positionOf(afterE4);
      expect((await evaluator.evaluate(position) as Evaluated).eval.cp, -80);
      await evaluator.evaluate(position);
      expect(calls, 1);
      expect(local.asked, isEmpty);
    },
  );

  test('a ChessDB score is centipawns up to the mate base, and mate in up to '
      '999 past it; anything else is no score', () {
    expect(chessDbCp(mateBaseCp)?.cp, mateBaseCp);
    expect(chessDbCp(-mateBaseCp)?.cp, -mateBaseCp);
    expect(chessDbCp(30000)?.cp, mateBaseCp);
    expect(chessDbCp(29001)?.cp, mateBaseCp - 999);
    expect(chessDbCp(-29001)?.cp, -(mateBaseCp - 999));
    expect(chessDbCp(29000), isNull);
    expect(chessDbCp(30001), isNull);
    expect(chessDbCp(-30001), isNull);
  });

  test('a cloud answer of the wrong shape, or with no line, is no score; one '
      'exactly as deep as asked is one', () {
    Eval? score(String body) =>
        lichessScore(body, whiteToMove: true, minDepth: 20);
    expect(score('[]'), isNull);
    expect(score('<html>blocked</html>'), isNull);
    expect(score(''), isNull);
    expect(score('{"depth":30}'), isNull);
    expect(score('{"depth":30,"pvs":[]}'), isNull);
    expect(score('{"depth":30,"pvs":[1]}'), isNull);
    expect(score('{"depth":20,"pvs":[{"cp":15}]}')?.cp, 15);
    expect(score('{"depth":20,"pvs":[{"mate":499}]}'), isNotNull);
    expect(score('{"depth":20,"pvs":[{"mate":500}]}'), isNull);
    expect(score('{"depth":20,"pvs":[{"mate":1}]}')?.cp, mateBaseCp - 2);
    expect(score('{"depth":20,"pvs":[{"mate":0}]}'), isNull);
  });

  test('a cloud score for Black to move is turned to Black\'s side', () async {
    final evaluator = SearchEvaluator(
      source: EvaluationSource.lichess,
      fallback: ScriptedEvaluator(),
      minDepth: 14,
      run: RemoteQueue(
        MockClient(
          (_) async => http.Response('{"depth":22,"pvs":[{"cp":50}]}', 200),
        ),
      ).run(),
    );
    addTearDown(evaluator.close);
    final afterE4 = positionOf(
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
    );
    final answer = await evaluator.evaluate(afterE4) as Evaluated;
    expect(answer.eval.cp, -50);
  });

  test('a lookup still out when the search stops is not used', () async {
    final answer = Completer<http.Response>();
    final evaluator = SearchEvaluator(
      source: EvaluationSource.lichess,
      fallback: ScriptedEvaluator(),
      minDepth: 14,
      run: RemoteQueue(MockClient((_) => answer.future)).run(),
    );
    final evaluating = evaluator.evaluate(positionOf(kingAndPawn));
    await pumpEventQueue();
    evaluator.close();
    answer.complete(http.Response('{"depth":22,"pvs":[{"cp":30}]}', 200));
    expect(
      (await evaluating as EvaluationUnavailable).reason,
      'The search was stopped.',
    );
  });
}
