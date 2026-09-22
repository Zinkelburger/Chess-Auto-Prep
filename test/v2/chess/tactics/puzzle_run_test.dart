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
    expect(run.after(c), isNull, reason: 'a run never wraps round');
  });

  test('after stepping back, the next is the one shown after it', () {
    // All three shown, back from c to b: next is c again, then the end.
    final all = const PuzzleRun(queue: [a, b, c]).shown(a).shown(b).shown(c);
    expect(all.after(b), c);
    expect(all.after(c), isNull);
    // a and b shown, back from b to a: next is b, not c.
    final two = const PuzzleRun(queue: [a, b, c]).shown(a).shown(b);
    expect(two.after(a), b);
    expect(two.after(b), c);
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
