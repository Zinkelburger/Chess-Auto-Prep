import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const LineKey key = (source: 'book.pgn', id: 'line-1');

  MoveStreak answer(MoveStreak? was, bool correct) =>
      streakAfter(was, key: key, ply: 4, correct: correct);

  test('a first right answer starts a streak of one, not yet learned', () {
    expect(
      answer(null, true),
      const MoveStreak(key: key, ply: 4, streak: 1, learned: false),
    );
  });

  test('two right answers are not yet learned', () {
    final two = answer(answer(null, true), true);
    expect(two.streak, 2);
    expect(two.learned, isFalse);
  });

  test('three right answers in a row make the move learned', () {
    final three = answer(answer(answer(null, true), true), true);
    expect(learnedStreak, 3);
    expect(three.streak, 3);
    expect(three.learned, isTrue);
  });

  test('a streak stops at three and stays learned', () {
    var streak = answer(null, true);
    for (var i = 0; i < 5; i++) {
      streak = answer(streak, true);
    }
    expect(streak.streak, learnedStreak);
    expect(streak.learned, isTrue);
  });

  test('a wrong answer starts over, even after the move was learned', () {
    const learned = MoveStreak(key: key, ply: 4, streak: 3, learned: true);
    expect(
      answer(learned, false),
      const MoveStreak(key: key, ply: 4, streak: 0, learned: false),
    );
  });
}
