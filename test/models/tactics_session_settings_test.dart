import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/models/tactics_session_settings.dart';
import 'package:flutter_test/flutter_test.dart';

TacticsPosition _pos({
  required String fen,
  String mistakeType = '??',
  int rating = 0,
  int reviewCount = 0,
}) {
  return TacticsPosition(
    fen: fen,
    gameWhite: 'A',
    gameBlack: 'B',
    gameResult: '1-0',
    gameDate: '2024.01.01',
    gameId: fen,
    positionContext: 'Move 1 — White to play',
    userMove: 'd4',
    correctLine: const ['e4'],
    mistakeType: mistakeType,
    mistakeAnalysis: 'test',
    rating: rating,
    reviewCount: reviewCount,
  );
}

void main() {
  group('TacticsSessionSettings.accepts / countMatching', () {
    test('default settings include blunders and mistakes, exclude inaccuracies',
        () {
      const settings = TacticsSessionSettings();
      expect(settings.accepts(_pos(fen: 'a', mistakeType: '??')), isTrue);
      expect(settings.accepts(_pos(fen: 'b', mistakeType: '?')), isTrue);
      expect(settings.accepts(_pos(fen: 'c', mistakeType: '?!')), isFalse);
    });

    test('1-star positions are excluded unless includeOneStar', () {
      const excluded = TacticsSessionSettings();
      const included = TacticsSessionSettings(includeOneStar: true);
      final oneStar = _pos(fen: 'a', rating: 1);
      expect(excluded.accepts(oneStar), isFalse);
      expect(included.accepts(oneStar), isTrue);
    });

    test('skipReviewed excludes positions already reviewed', () {
      const skip = TacticsSessionSettings(skipReviewed: true);
      expect(skip.accepts(_pos(fen: 'a', reviewCount: 0)), isTrue);
      expect(skip.accepts(_pos(fen: 'b', reviewCount: 3)), isFalse);
    });

    test('countMatching matches the number that would enter a session', () {
      const settings = TacticsSessionSettings();
      final positions = [
        _pos(fen: '1', mistakeType: '??'), // included
        _pos(fen: '2', mistakeType: '?'), // included
        _pos(fen: '3', mistakeType: '?!'), // excluded (inaccuracy)
        _pos(fen: '4', mistakeType: '??', rating: 1), // excluded (1-star)
      ];
      // The "ready" count shown on the Start button must reflect exactly the
      // filtered set — here 2 of 4 — so the label can never disagree with the
      // session that actually launches.
      expect(settings.countMatching(positions), 2);
    });

    test('mistakeTypes filter is honoured exactly', () {
      const blundersOnly = TacticsSessionSettings(mistakeTypes: {'??'});
      final positions = [
        _pos(fen: '1', mistakeType: '??'),
        _pos(fen: '2', mistakeType: '?'),
        _pos(fen: '3', mistakeType: '?!'),
      ];
      expect(blundersOnly.countMatching(positions), 1);
    });
  });
}
