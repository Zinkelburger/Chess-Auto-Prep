// The Bughouse lab's smaller rules: text with no game in it is refused, not
// read; a click into a board makes it the one worked on, as does a step
// back that takes both boards back; and a new game after a file of several
// is no game of that file.
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late BughouseLab lab;
  setUp(() => lab = BughouseLab());
  tearDown(() => lab.dispose());

  test('blank text is refused', () {
    expect(() => lab.pasteMoves('  \n\n'), returnsNormally);
    expect(lab.problem, isNotNull);
  });

  test('a click into board 2 makes it the one worked on', () {
    lab.showBoards(LabBoards.two);
    expect(lab.focus, BoardNumber.one);
    lab.focusOn(BoardNumber.two);
    expect(lab.focus, BoardNumber.two);
  });

  test('back to board 1\'s first move, before board 2 moved, works on board '
      '1', () {
    lab
      ..showBoards(LabBoards.two)
      ..play(BoardNumber.one, 'e2e4')
      ..play(BoardNumber.one, 'd7d5')
      ..play(BoardNumber.one, 'e4d5')
      ..play(BoardNumber.two, 'e2e4')
      ..play(BoardNumber.two, 'P@d5');
    final first = lab.line.lineOf(BoardNumber.one).first;
    lab.goTo(BoardNumber.one, first);
    expect(lab.line.upto(BoardNumber.two), 0);
    expect(lab.focus, BoardNumber.one);
  });

  test('a new game after a file of several is no game of it', () {
    String game(int round) =>
        '[Event "Club night"]\n[Round "$round"]\n\n1A. e4 1a. d5 1-0\n\n';
    lab.pasteMoves(game(1) + game(2), file: 'night.bpgn');
    lab.showGame(1);
    expect(lab.gameAt, 1);
    lab.newGame();
    expect(lab.gameAt, 0);
    expect(lab.gameCount, 0);
  });
}
