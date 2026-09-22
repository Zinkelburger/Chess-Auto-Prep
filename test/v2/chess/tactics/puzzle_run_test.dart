import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle_run.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const a = Fen('a'), b = Fen('b'), c = Fen('c');

  test('the next puzzle is the first after the current one not yet shown, '
      'and nothing after the last', () {
    var run = const PuzzleRun(queue: [a, b, c]);
    expect(run.after(null), a);
    run = run.shown(a);
    expect(run.after(a), b);
    run = run.shown(c);
    expect(run.after(a), b);
    expect(run.after(c), isNull);
  });

  test(
    'a puzzle from outside the queue is followed by the first not shown',
    () {
      final run = const PuzzleRun(queue: [a, b]).shown(a).shown(c);
      expect(run.after(c), b);
    },
  );

  test('the first attempt decides a puzzle', () {
    final run = const PuzzleRun(
      queue: [a],
    ).shown(a).decided(a, Outcome.failed, 4).decided(a, Outcome.solved, 9);
    expect(run.outcomes, {a: Outcome.failed});
    expect(run.seconds, {a: 4});
  });

  test('the recap counts solved, failed and skipped, and offers the failed '
      'and skipped again in the order they came', () {
    final recap = const PuzzleRun(queue: [a, b, c])
        .shown(a)
        .decided(a, Outcome.solved, 10)
        .shown(b)
        .decided(b, Outcome.failed, 20)
        .shown(c)
        .recap;
    expect((recap.solved, recap.failed, recap.skipped), (1, 1, 1));
    expect(recap.seconds, 30);
    expect(recap.accuracy, 0.5);
    expect(recap.retry, [b, c]);
    expect(const PuzzleRun(queue: [a]).recap.accuracy, isNull);
  });
}
