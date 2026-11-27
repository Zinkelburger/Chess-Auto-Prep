import 'package:chess_auto_prep/chess/bughouse/pv_steps.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:dartchess/dartchess.dart' show Role, Side;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pv = ['e2e4', 'e7e5', 'g1f3', 'b8c6'];

  test('a board\'s moves numbered as it counts them', () {
    final steps = pvSteps(TablePosition.initial, BoardNumber.one, pv);
    expect(steps.map((s) => '${s.label}|${s.san}'), [
      '1.|e4',
      '|e5',
      '2.|Nf3',
      '|Nc6',
    ]);
    expect(steps.every((s) => s.board == BoardNumber.one), isTrue);
    expect(steps.last.after.one.turn.name, 'white');
    expect(pvMovesTo(steps, 1), [
      (BoardNumber.one, 'e2e4'),
      (BoardNumber.one, 'e7e5'),
    ]);
  });

  test('board 2\'s line plays on board 2, the other board untouched', () {
    final steps = pvSteps(TablePosition.initial, BoardNumber.two, pv);
    expect(steps.last.after.one, TablePosition.initial.one);
    expect(pvMovesTo(steps, 0), [(BoardNumber.two, 'e2e4')]);
  });

  test('starting with Black numbers its first move with ...', () {
    final after = TablePosition.initial.play(BoardNumber.one, 'e2e4')!.after;
    final steps = pvSteps(after, BoardNumber.one, const ['e7e5', 'g1f3']);
    expect(steps.map((s) => s.label), ['1...', '2.']);
  });

  test('a capture crosses to the partner\'s hand along the line', () {
    final steps = pvSteps(TablePosition.initial, BoardNumber.one, const [
      'e2e4',
      'd7d5',
      'e4d5',
    ]);
    expect(steps.last.san, 'exd5');
    // A took a black pawn on board 1: it goes to A's partner B, Black on
    // board 2.
    expect(steps.last.after.two.pockets!.of(Side.black, Role.pawn), 1);
  });

  test('stops at exactly its limit of moves', () {
    final steps = pvSteps(TablePosition.initial, BoardNumber.one, pv, limit: 2);
    expect(steps.map((s) => s.san), ['e4', 'e5']);
  });

  test('playing to the first step plays it; before the first plays none', () {
    final steps = pvSteps(TablePosition.initial, BoardNumber.one, pv);
    expect(pvMovesTo(steps, 0), [(BoardNumber.one, 'e2e4')]);
    expect(pvMovesTo(steps, -1), isEmpty);
  });

  test('stops at the first move that does not play, a drop with nothing in '
      'hand among them', () {
    expect(
      pvSteps(TablePosition.initial, BoardNumber.one, const [
        'e2e4',
        'e2e4',
      ]).map((s) => s.san),
      ['e4'],
    );
    expect(
      pvSteps(TablePosition.initial, BoardNumber.one, const [
        'e2e4',
        'N@f6',
      ]).map((s) => s.san),
      ['e4'],
    );
  });
}
