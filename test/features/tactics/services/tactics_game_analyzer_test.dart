/// The pure parts of the mining pass: the mistake ladder, the opening
/// eval memo, and the Chess.com archive window. The full pass — which
/// swings become puzzles, what gets skipped, what the movetext says — is
/// driven end to end in `tactics_import_analysis_test.dart`.
library;

import 'package:chess_auto_prep/features/tactics/services/tactics_import_analysis.dart';
import 'package:chess_auto_prep/features/tactics/services/opening_eval_cache.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_game_fetcher.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripted_pool.dart';

void main() {
  group('MistakeSeverity.ofDelta', () {
    test('grades a winning-chance drop by the inclusive thresholds', () {
      expect(MistakeSeverity.ofDelta(0.0999), isNull);
      expect(MistakeSeverity.ofDelta(0.1), MistakeSeverity.inaccuracy);
      expect(MistakeSeverity.ofDelta(0.1999), MistakeSeverity.inaccuracy);
      expect(MistakeSeverity.ofDelta(0.2), MistakeSeverity.mistake);
      expect(MistakeSeverity.ofDelta(0.2999), MistakeSeverity.mistake);
      expect(MistakeSeverity.ofDelta(0.3), MistakeSeverity.blunder);
      expect(MistakeSeverity.ofDelta(1.5), MistakeSeverity.blunder);
      expect(MistakeSeverity.ofDelta(-0.4), isNull);
    });

    test('marks are the stored mistake types', () {
      expect(MistakeSeverity.blunder.mark, '??');
      expect(MistakeSeverity.mistake.mark, '?');
      expect(MistakeSeverity.inaccuracy.mark, '?!');
    });
  });

  group('OpeningEvalCache', () {
    const opening =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
    const middlegame =
        'r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP3PPP/R2QKB1R w KQ - 0 11';

    test('serves a repeated opening position from the memo', () async {
      final worker = ScriptedWorker()
        ..script[opening] = cp(30)
        ..script[middlegame] = cp(-10);
      final cache = OpeningEvalCache(depth: 8);

      final first = await cache.evaluate(worker, opening);
      final again = await cache.evaluate(worker, opening);
      expect(first.scoreCp, 30);
      expect(again.scoreCp, 30);
      expect(worker.searched, [opening], reason: 'one search, one memo hit');

      await cache.evaluate(worker, middlegame);
      await cache.evaluate(worker, middlegame);
      expect(
        worker.searched.where((f) => f == middlegame).length,
        2,
        reason: 'past fullmove 10 nothing is memoized',
      );
    });

    test('a failed search is not memoized', () async {
      final worker = ScriptedWorker();
      final cache = OpeningEvalCache(depth: 8);
      await expectLater(cache.evaluate(worker, opening), throwsStateError);

      worker.script[opening] = cp(15);
      expect((await cache.evaluate(worker, opening)).scoreCp, 15);
      expect(worker.searched, [opening, opening]);
    });
  });

  group('TacticsGameFetcher.firstArchiveIndexSince', () {
    const archives = [
      'https://api.chess.com/pub/player/u/games/2024/03',
      'https://api.chess.com/pub/player/u/games/2024/05',
      'https://api.chess.com/pub/player/u/games/2024/06',
    ];

    test('finds the first month that can hold games on or after since', () {
      expect(
        TacticsGameFetcher.firstArchiveIndexSince(
          archives,
          DateTime(2024, 5, 20),
        ),
        1,
      );
      expect(
        TacticsGameFetcher.firstArchiveIndexSince(archives, DateTime(2023)),
        0,
      );
    });

    test('falls back to the oldest archive when none qualifies', () {
      expect(
        TacticsGameFetcher.firstArchiveIndexSince(archives, DateTime(2025)),
        0,
      );
      expect(
        TacticsGameFetcher.firstArchiveIndexSince(const [
          'not/a/date',
        ], DateTime(2024)),
        0,
      );
    });
  });
}
