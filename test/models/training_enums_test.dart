import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:chess_auto_prep/models/line_status.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReviewOrder storage', () {
    test('every order round-trips through its storage value', () {
      for (final order in ReviewOrder.values) {
        expect(ReviewOrder.fromStorage(order.storageValue), order);
      }
    });

    test('unset or unknown reads as byImportance', () {
      expect(ReviewOrder.fromStorage(null), ReviewOrder.byImportance);
      expect(ReviewOrder.fromStorage('nope'), ReviewOrder.byImportance);
    });
  });

  group('ChapterGroupingMode storage', () {
    test('every mode round-trips through its storage value', () {
      for (final mode in ChapterGroupingMode.values) {
        expect(ChapterGroupingMode.fromStorage(mode.storageValue), mode);
      }
    });

    test('unset or unknown reads as auto', () {
      expect(ChapterGroupingMode.fromStorage(null), ChapterGroupingMode.auto);
      expect(ChapterGroupingMode.fromStorage('x'), ChapterGroupingMode.auto);
    });
  });

  test('labels are spelled out', () {
    expect(TrainingMode.tactics.label, 'Tactics');
    expect(RepetitionMode.spaced.label, 'Spaced repetition');
    expect(TrainingIntent.review.label, 'Review');
    expect(LineStatus.untrained.label, 'Untrained');
    expect(LineStatus.due.actionLabel, 'Review');
  });

  group('GameResult', () {
    test('carries the PGN token and White points', () {
      expect(GameResult.whiteWins.pgnToken, '1-0');
      expect(GameResult.draw.pgnToken, '1/2-1/2');
      expect(GameResult.blackWins.whitePoints, 0);
      expect(GameResult.unfinished.whitePoints, 0.5);
    });
  });

  group('TerminationReason', () {
    test('maps to the PGN Termination vocabulary', () {
      expect(TerminationReason.checkmate.pgnTag, 'normal');
      expect(TerminationReason.mutualSitting.pgnTag, 'adjudication');
      expect(TerminationReason.aborted.pgnTag, 'unterminated');
      expect(TerminationReason.stalemate.isNaturalEnd, isTrue);
      expect(TerminationReason.timeForfeit.isNaturalEnd, isFalse);
    });
  });
}
