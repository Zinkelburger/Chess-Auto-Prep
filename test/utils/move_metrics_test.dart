/// The reader for the generator's `[%...]` move tokens.
///
/// The writer (`generation/export/move_annotation.dart`) and this reader are
/// the two halves of one wire format, and the export is worthless if the app
/// silently drops half of it — so every token the writer can emit is pinned
/// here, together with the plain English it turns into.
library;

import 'package:chess_auto_prep/utils/pgn_comment_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MoveMetrics.parse', () {
    test('reads every token a full-detail export writes', () {
      final metrics = MoveMetrics.parse(
        '[%maiaProbability 0.420] [%eval +0.31] [%expectimax +0.78] '
        '[%onlyMove] [%myEase 0.81] [%ease 0.42] [%score 54.2%] '
        '[%games 128] [%lastPlayed 2024]',
      );

      expect(metrics.likelihood, closeTo(0.42, 1e-9));
      expect(metrics.likelihoodSource, MoveLikelihoodSource.maia);
      expect(metrics.evalCp, 31);
      expect(metrics.expectimaxCp, 78);
      expect(metrics.isOnlyMove, isTrue);
      expect(metrics.myEase, closeTo(0.81, 1e-9));
      expect(metrics.opponentEase, closeTo(0.42, 1e-9));
      expect(metrics.practicalScore, closeTo(0.542, 1e-9));
      expect(metrics.gameCount, 128);
      expect(metrics.lastPlayedYear, 2024);
    });

    test('tells the three likelihood sources apart', () {
      expect(
        MoveMetrics.parse('[%humanFrequency 0.4]').likelihoodSource,
        MoveLikelihoodSource.gameDatabase,
      );
      expect(
        MoveMetrics.parse('[%engineReply 0.05]').likelihoodSource,
        MoveLikelihoodSource.engine,
      );
      expect(
        MoveMetrics.parse('[%maiaProbability 0.4]').likelihoodSource,
        MoveLikelihoodSource.maia,
      );
    });

    test('reads a mate score as a distance, not a centipawn value', () {
      final metrics = MoveMetrics.parse('[%eval #3]');

      expect(metrics.evalMate, 3);
      expect(metrics.evalCp, isNull);
      expect(metrics.labels, ['mate in 3']);
    });

    test('reads what a refuted alternative costs', () {
      expect(MoveMetrics.parse('[%loss 4.30]').lossCp, 430);
    });

    test('a comment with no tokens is empty, not a row of zeroes', () {
      final metrics = MoveMetrics.parse(
        'A human wrote this. 1... Nf6 is fine.',
      );

      expect(metrics.isEmpty, isTrue);
      expect(metrics.labels, isEmpty);
      expect(metrics.evalCp, isNull);
      expect(metrics.isOnlyMove, isFalse);
    });

    test('unknown tokens are ignored rather than guessed at', () {
      final metrics = MoveMetrics.parse(
        '[%clk 0:05:00] [%cal Ge2e4] '
        '[%eval -1.05]',
      );

      expect(metrics.evalCp, -105);
      expect(metrics.labels, ['eval -1.05']);
    });
  });

  group('MoveMetrics.labels', () {
    test('spell out what each number means, in reading order', () {
      final metrics = MoveMetrics.parse(
        '[%maiaProbability 0.42] [%eval +0.31] [%onlyMove] [%myEase 0.81] '
        '[%ease 0.4] [%score 54.0%] [%games 128] [%lastPlayed 2024]',
      );

      expect(metrics.labels, [
        'eval +0.31',
        'only move',
        '42% likely',
        '128 games',
        'you score 54%',
        'natural for you 81%',
        'easy for them 40%',
        'last played 2024',
      ]);
    });

    test(
      'name the source of a likelihood, since they mean different things',
      () {
        expect(
          MoveMetrics.parse('[%humanFrequency 0.42]').summary,
          'played 42%',
        );
        expect(
          MoveMetrics.parse('[%engineReply 0.05]').summary,
          'engine reply',
        );
      },
    );

    test('a zero game count claims no games rather than "0 games"', () {
      expect(MoveMetrics.parse('[%games 0] [%lastPlayed 0]').labels, isEmpty);
    });

    test('join into one line for display', () {
      expect(
        MoveMetrics.parse('[%eval +0.31] [%onlyMove]').summary,
        'eval +0.31 · only move',
      );
    });

    test('expectimax reads beside eval so the gap is visible at a glance', () {
      final metrics = MoveMetrics.parse('[%eval +0.10] [%expectimax +0.45]');
      expect(metrics.labels, ['eval +0.10', 'expectimax +0.45']);
      expect(
        MoveMetrics.parse('[%expectimax -0.30]').summary,
        'expectimax -0.30',
      );
    });
  });
}
