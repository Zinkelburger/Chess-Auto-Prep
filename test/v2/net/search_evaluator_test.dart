import 'package:chess_auto_prep/v2/chess/generation/evaluation_source.dart';
import 'package:chess_auto_prep/v2/chess/generation/sources.dart';
import 'package:chess_auto_prep/v2/net/search_evaluator.dart';
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

  test(
    'a rate limit stops remote requests for the run and falls back',
    () async {
      var calls = 0;
      final local = ScriptedEvaluator(fallback: 42);
      final evaluator = SearchEvaluator(
        source: EvaluationSource.lichess,
        fallback: local,
        minDepth: 14,
        client: MockClient((_) async {
          calls++;
          return http.Response('', 429);
        }),
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
        client: MockClient((uri) async {
          calls++;
          expect(uri.url.queryParameters['learn'], '0');
          return http.Response('eval:-80', 200);
        }),
      );
      addTearDown(evaluator.close);
      final position = positionOf(afterE4);
      expect((await evaluator.evaluate(position) as Evaluated).eval.cp, -80);
      await evaluator.evaluate(position);
      expect(calls, 1);
      expect(local.asked, isEmpty);
    },
  );
}
