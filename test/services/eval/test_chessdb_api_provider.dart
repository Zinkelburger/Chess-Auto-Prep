import 'package:chess_auto_prep/services/eval/chessdb_api_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('parseChessDbQueryScoreBody', () {
    test('parses plain eval line', () {
      final hit = parseChessDbQueryScoreBody('eval:42', fen);
      expect(hit, isNotNull);
      expect(hit!.cp, 42);
    });

    test('returns null for unknown', () {
      expect(parseChessDbQueryScoreBody('unknown', fen), isNull);
    });

    test('returns null for rate limit message', () {
      expect(parseChessDbQueryScoreBody('rate limit exceeded', fen), isNull);
    });

    test('parses JSON eval', () {
      final hit = parseChessDbQueryScoreBody(
        '{"status":"ok","eval":-30,"depth":18}',
        fen,
      );
      expect(hit, isNotNull);
      expect(hit!.cp, -30);
      expect(hit.depth, 18);
    });

    test('maps mate scores', () {
      final mapped = mapChessDbApiScore(29996, isWhiteToMove: true);
      expect(mapped, isNotNull);
      expect(mapped!.$2, 4);
    });
  });

  group('ChessDbApiProvider', () {
    test('lookup increments quota on hit', () async {
      final provider = ChessDbApiProvider(
        dailyQuota: 10,
        httpFetch: (_) async => http.Response('eval:15', 200),
      );
      await provider.init();

      final result = await provider.lookup(fen, minDepth: 0);
      expect(result.isHit, isTrue);
      expect(provider.usedToday, 1);
    });

    test('lookup returns miss when quota exhausted', () async {
      SharedPreferences.setMockInitialValues({
        'chessdb_api_quota_date':
            '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}',
        'chessdb_api_quota_count': 5,
      });

      final provider = ChessDbApiProvider(
        dailyQuota: 5,
        httpFetch: (_) async => http.Response('eval:15', 200),
      );
      await provider.init();
      expect(provider.quotaRemaining, isFalse);

      final result = await provider.lookup(fen, minDepth: 0);
      expect(result.isHit, isFalse);
    });

    test('lookup returns shallow when depth too low', () async {
      final provider = ChessDbApiProvider(
        httpFetch: (_) async => http.Response(
          '{"status":"ok","eval":10,"depth":12}',
          200,
        ),
      );
      await provider.init();

      final result = await provider.lookup(fen, minDepth: 18);
      expect(result.shallow, isTrue);
    });

    test('respects concurrency limit', () async {
      var inFlight = 0;
      var maxInFlight = 0;

      final provider = ChessDbApiProvider(
        dailyQuota: 100,
        concurrency: 2,
        httpFetch: (_) async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          inFlight--;
          return http.Response('eval:1', 200);
        },
      );
      await provider.init();

      await Future.wait([
        provider.lookup(fen, minDepth: 0),
        provider.lookup(fen, minDepth: 0),
        provider.lookup(fen, minDepth: 0),
      ]);

      expect(maxInFlight, lessThanOrEqualTo(2));
    });
  });
}
