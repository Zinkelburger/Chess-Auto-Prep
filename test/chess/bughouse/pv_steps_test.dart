import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/pv_steps.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pv = [
    JointMove('e2e4', 'd2d4'),
    JointMove('e7e5', null),
    JointMove(null, null),
    JointMove('g1f3', 'd7d5'),
  ];

  test('one board: its moves numbered, the other board played unseen', () {
    final steps = pvSteps(TablePosition.initial, pv, board: BoardNumber.one);
    expect(steps.map((s) => '${s.label}|${s.san}'), ['1.|e4', '|e5', '2.|Nf3']);
    // The table after Nf3 has board 2's d4, played before it, too.
    expect(steps.last.after.two.turn.name, 'black');
    expect(pvMovesTo(steps, 1), [
      (BoardNumber.one, 'e2e4'),
      (BoardNumber.one, 'e7e5'),
    ]);
  });

  test('one board through both: a step plays the other board before it', () {
    final steps = pvSteps(
      TablePosition.initial,
      pv,
      board: BoardNumber.one,
      throughBoth: true,
    );
    expect(steps.map((s) => s.san), ['e4', 'e5', 'Nf3']);
    expect(pvMovesTo(steps, 2), [
      (BoardNumber.one, 'e2e4'),
      (BoardNumber.two, 'd2d4'),
      (BoardNumber.one, 'e7e5'),
      (BoardNumber.one, 'g1f3'),
    ]);
  });

  test('one board starting with Black numbers its first move with ...', () {
    final after = TablePosition.initial.play(BoardNumber.one, 'e2e4')!.after;
    final steps = pvSteps(after, [
      const JointMove('e7e5', null),
    ], board: BoardNumber.one);
    expect(steps.single.label, '1...');
  });

  test('two boards: every move seat-lettered, a still action a sit', () {
    final steps = pvSteps(TablePosition.initial, pv, limit: 3);
    expect(steps.map((s) => '${s.label} ${s.san} ${s.joint}'), [
      'A e4 0',
      'D d4 0',
      'C e5 1',
      ' sit 2',
    ]);
    expect(steps[1].board, BoardNumber.two);
    expect(steps[1].after.two.turn.name, 'black');
    expect(pvMovesTo(steps, 3), [
      (BoardNumber.one, 'e2e4'),
      (BoardNumber.two, 'd2d4'),
      (BoardNumber.one, 'e7e5'),
    ]);
  });

  test('a line stops at the first move that does not play', () {
    final steps = pvSteps(TablePosition.initial, const [
      JointMove('e2e4', null),
      JointMove('e2e4', null),
    ]);
    expect(steps.map((s) => s.san), ['e4']);
  });
}
