import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/chess/training/sitting.dart';
import 'package:chess_auto_prep/chess/training/training_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 22, 12);

  // A Black chapter: an introduction with no Black move in it, two lines,
  // and a model game.
  final lines = trainingLines(
    parseChapter(
      name: 'Main',
      text: '''
// Color: Black

[Event "Introduction"]

{How the chapter goes.} 1. e4 *

[Event "Open"]

1. e4 e5 *

[Event "Sicilian"]

1. e4 c5 *

[Event "A model game"]
[Result "0-1"]

1. e4 c5 0-1
''',
    ),
    source: '/repertoires/KID/Main.pgn',
  );

  test('the counts leave out a line with none of the user\'s moves, as '
      'Learn and Review do', () {
    final counts = countsOf(lines, const {}, now);
    expect(counts[LineStatus.untrained], toLearn(lines, const {}, now).length);
    expect(counts[LineStatus.untrained], 2);
    expect(counts[LineStatus.game], 1);

    final intro = lines.first;
    final reviews = {
      intro.key: Review(
        key: intro.key,
        lineName: intro.name,
        intervalDays: 1,
        lastRating: 'good',
        due: now.subtract(const Duration(days: 1)),
      ),
    };
    expect(countsOf(lines, reviews, now)[LineStatus.due], 0);
    expect(dueNow(lines, reviews, now), isEmpty);
  });

  group('lines due now', () {
    final open = lines[1];
    final sicilian = lines[2];
    Review dueOn(TrainingLine line, DateTime due) => Review(
      key: line.key,
      lineName: line.name,
      intervalDays: 1,
      lastRating: 'good',
      due: due,
    );

    test('come longest overdue first, each with one move of the user\'s', () {
      expect((open.yourMoves, sicilian.yourMoves), (1, 1));
      final reviews = {
        open.key: dueOn(open, now.subtract(const Duration(days: 1))),
        sicilian.key: dueOn(sicilian, now.subtract(const Duration(days: 3))),
      };
      expect(dueNow(lines, reviews, now), [sicilian, open]);
    });

    test('keep file order when due at once', () {
      final yesterday = now.subtract(const Duration(days: 1));
      final reviews = {
        sicilian.key: dueOn(sicilian, yesterday),
        open.key: dueOn(open, yesterday),
      };
      expect(dueNow(lines, reviews, now), [open, sicilian]);
    });
  });
}
