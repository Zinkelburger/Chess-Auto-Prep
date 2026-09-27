import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/training/line_order.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/chess/training/training_line.dart';
import 'package:flutter_test/flutter_test.dart';

const _chapter = '''
// Color: White

[Event "Learned"]
[CumProb "0.2"]

1. e4 e5 2. Nf3 *

[Event "New"]
[CumProb "41.5%"]

1. e4 c5 2. Nf3 *

[Event "Due"]

1. e4 e6 2. d4 *

[Event "Old header"]
[Importance "0.3"]

1. e4 c6 2. d4 *

[Event "A game"]
[Result "1-0"]

1. e4 d5 2. exd5 1-0
''';

void main() {
  final now = DateTime.utc(2026, 9, 22, 12);
  final lines = trainingLines(
    parseChapter(name: 'Main', text: _chapter),
    source: '/r/Main.pgn',
  );
  Review review(int index, {required DateTime due}) => Review(
    key: lines[index].key,
    lineName: lines[index].name,
    intervalDays: 3,
    due: due,
    lastRating: 'good',
    lastReviewed: now,
    passes: 1,
  );
  final reviews = {
    lines[0].key: review(0, due: now.add(const Duration(days: 3))),
    lines[2].key: review(2, due: now.subtract(const Duration(days: 1))),
  };
  List<String> names(LineOrder order) => [
    for (final line in ordered(lines, order, reviews: reviews, now: now))
      line.name,
  ];

  test('a generated line says how likely it is, in either spelling', () {
    expect(
      [for (final l in lines) l.likelihood],
      [0.2, 0.415, null, 0.3, null],
    );
  });

  test('course order is the file', () {
    expect(names(LineOrder.course), [
      'Learned',
      'New',
      'Due',
      'Old header',
      'A game',
    ]);
  });

  test('training order: due, new, learned, then games', () {
    expect(names(LineOrder.training), [
      'Due',
      'New',
      'Old header',
      'Learned',
      'A game',
    ]);
  });

  test('the likeliest first, lines that do not say last in file order', () {
    expect(names(LineOrder.likely), [
      'New',
      'Old header',
      'Learned',
      'Due',
      'A game',
    ]);
  });

  test('the likeliest first needs a file that says', () {
    expect(canOrder(lines, LineOrder.likely), isTrue);
    expect(canOrder([lines[2]], LineOrder.likely), isFalse);
    expect(canOrder([lines[2]], LineOrder.course), isTrue);
  });
}
