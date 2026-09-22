import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/training/drill.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/training_line.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1. e4 e5 2. Nf3 Nc6 3. Bb5, trained as White.
const _white = '''
// Color: White

[Event "Ruy"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 *
''';

/// The same moves, trained as Black.
const _black = '''
// Color: Black

[Event "Ruy"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 *
''';

TrainingLine _line(String text) => trainingLines(
  parseChapter(name: 'Main', text: text),
  source: '/r/Main.pgn',
).single;

/// Plays [uci] and returns the drill after it, failing when it was not
/// taken as an answer.
Drill _play(Drill drill, String uci) {
  final answered = drill.answer(uci);
  expect(answered, isNotNull, reason: '$uci was not asked for');
  return answered!.$1;
}

/// Ticks through timed stages until the drill waits on the user.
Drill _settle(Drill drill) {
  var d = drill;
  while (d.timed) {
    d = d.tick();
  }
  return d;
}

void main() {
  group('a quiz', () {
    test('asks for each of the user\'s moves and plays the replies', () {
      var d = Drill.start(_line(_white), learn: false);
      expect((d.pass, d.stage.runtimeType, d.shown), (Pass.quiz, Asking, 0));
      d = _settle(_play(d, 'e2e4'));
      expect((d.stage.runtimeType, d.shown, d.expected), (Asking, 2, 'Nf3'));
      d = _settle(_play(d, 'g1f3'));
      d = _settle(_play(d, 'f1b5'));
      expect(d.stage, isA<Finished>());
      expect((d.stage as Finished).clean, isTrue);
    });

    test('for Black, starts with the opponent\'s move on the board', () {
      final d = Drill.start(_line(_black), learn: false);
      expect((d.stage.runtimeType, d.shown, d.lastMove), (Asking, 1, 'e2e4'));
      expect(d.expected, 'e5');
    });

    test('a wrong move stays on the board, then the right one replaces it', () {
      var d = Drill.start(_line(_white), learn: false);
      final (missed, answer) = d.answer('d2d4')!;
      expect(answer.correct, isFalse);
      expect((answer.played, answer.expected, answer.ply), ('d4', 'e4', 0));
      expect(answer.phase, AttemptPhase.drilling);
      expect(missed.stage, isA<Missed>());
      expect(missed.lastMove, 'd2d4');
      d = missed.tick();
      expect((d.stage.runtimeType, d.lastMove), (Corrected, 'e2e4'));
      d = _settle(d);
      expect((d.stage.runtimeType, d.expected), (Asking, 'Nf3'));
    });

    test('the missed moves are replayed on their own, then it finishes', () {
      var d = Drill.start(_line(_white), learn: false);
      d = _settle(_play(d, 'e2e4'));
      d = _settle(_play(d, 'b1c3')); // wrong: Nf3
      d = _settle(_play(d, 'f1b5'));
      expect((d.pass, d.stage.runtimeType, d.shown), (Pass.replay, Asking, 2));
      expect(d.replaying, [2]);
      final (replayed, answer) = d.answer('g1f3')!;
      expect(answer.phase, AttemptPhase.replaying);
      d = _settle(replayed);
      expect(d.stage, isA<Finished>());
      expect((d.stage as Finished).clean, isFalse);
    });

    test('a move reaching the same position counts, however it is spelled', () {
      // Two knights can reach f3 only one way here, but the answer is
      // compared by position, not by text.
      final d = Drill.start(_line(_white), learn: false);
      expect(d.answer('e2e4')!.$2.correct, isTrue);
    });

    test('an illegal move or one while nothing is asked is no answer', () {
      final d = Drill.start(_line(_white), learn: false);
      expect(d.answer('e2e5'), isNull);
      expect(_play(d, 'e2e4').answer('g1f3'), isNull);
    });
  });

  group('a walkthrough', () {
    test('shows each move, then asks for it, then quizzes the line', () {
      var d = Drill.start(_line(_white), learn: true);
      expect(
        (d.pass, d.stage.runtimeType, d.shown, d.lastMove),
        (Pass.walkthrough, Showing, 1, 'e2e4'),
      );
      d = d.next();
      expect((d.stage.runtimeType, d.shown), (Asking, 0));
      final (played, answer) = d.answer('e2e4')!;
      expect(answer.phase, AttemptPhase.learning);
      d = _settle(played);
      expect((d.stage.runtimeType, d.expected), (Showing, 'Nf3'));
      d = _settle(_play(d.next(), 'g1f3'));
      d = _settle(_play(d.next(), 'f1b5'));
      expect((d.pass, d.stage.runtimeType, d.shown), (Pass.quiz, Asking, 0));
    });

    test('lets the opponent\'s move be seen before the next one to learn', () {
      var d = Drill.start(_line(_black), learn: true);
      expect((d.stage.runtimeType, d.shown), (Answered, 1));
      d = d.tick();
      expect((d.stage.runtimeType, d.shown, d.expected), (Showing, 2, 'e5'));
    });

    test('a wrong answer is corrected and asked again, and does not count', () {
      var d = Drill.start(_line(_white), learn: true).next();
      d = _play(d, 'd2d4');
      expect(d.missed, isEmpty);
      d = d.tick().tick();
      expect((d.stage.runtimeType, d.shown, d.expected), (Asking, 0, 'e4'));
    });
  });
}
