import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/features/bughouse/bughouse_lab.dart';
import 'package:dartchess/dartchess.dart' show Role, Side;
import 'package:flutter_test/flutter_test.dart';

const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void main() {
  late BughouseLab lab;

  setUp(() => lab = BughouseLab());
  tearDown(() => lab.dispose());

  /// Board 1 takes a pawn; board 2's Black may drop it.
  void capture() {
    lab.play(BoardNumber.one, 'e2e4');
    lab.play(BoardNumber.one, 'd7d5');
    lab.play(BoardNumber.one, 'e4d5');
  }

  test('a capture on one board is a drop on the other', () {
    capture();
    lab.play(BoardNumber.two, 'e2e4');
    lab.play(BoardNumber.two, 'P@d5');
    expect(lab.problem, isNull);
    expect(lab.line.of(BoardNumber.two).map((m) => m.san), ['e4', 'P@d5']);
    expect(lab.position.two.pockets!.of(Side.black, Role.pawn), 0);
    expect(lab.focus, BoardNumber.two);
  });

  test('an illegal drop, or a move out of turn, is refused in words', () {
    lab.play(BoardNumber.two, 'N@e5');
    expect(lab.problem, 'That drop is not legal.');
    lab.play(BoardNumber.one, 'e7e5');
    expect(lab.problem, 'It is not black’s turn on board 1.');
    // The next move that plays clears it.
    lab.play(BoardNumber.one, 'e2e4');
    expect(lab.problem, isNull);
  });

  test('each board steps on its own; a step that breaks a drop is refused', () {
    capture();
    lab.play(BoardNumber.two, 'e2e4');
    lab.play(BoardNumber.two, 'P@d5');
    lab.go(BoardNumber.two, 1);
    expect(lab.line.upto(BoardNumber.one), 3);
    lab.go(BoardNumber.two, 2);
    lab.go(BoardNumber.one, 2);
    expect(
      lab.problem,
      contains('P@d5 on board 2 would have no piece to drop'),
    );
    expect(lab.line.upto(BoardNumber.one), 3);
    expect(lab.focus, BoardNumber.one);
  });

  test('the arrow keys step the focused board and stop at its ends', () {
    capture();
    lab.step(-1);
    expect(lab.line.upto(BoardNumber.one), 2);
    lab.toStart();
    lab.step(-1);
    expect(lab.line.upto(BoardNumber.one), 0);
    lab.toEnd();
    expect(lab.line.upto(BoardNumber.one), 3);
  });

  test('a joint action plays both halves, a sitting board keeps still', () {
    lab.playJoint(const JointMove('e2e4', 'd2d4'));
    expect(lab.line.moves.map((m) => m.san), ['e4', 'd4']);
    lab.playJoint(const JointMove(null, 'e2e4'));
    expect(lab.problem, 'That line no longer fits the position.');
    expect(lab.line.moves.length, 2);
  });

  test('a new game or a set position starts a new line', () {
    capture();
    lab.newGame();
    expect(lab.line.moves, isEmpty);
    lab.setPosition(
      (fen: start, white: 'N', black: ''),
      (fen: start, white: '', black: 'K'),
    );
    expect(lab.setupProblems[BoardNumber.two], startsWith('Player B: '));
    lab.setPosition(
      (fen: start, white: 'N', black: ''),
      (fen: start, white: '', black: '2P'),
    );
    expect(lab.setupProblems, isEmpty);
    expect(lab.position.one.pockets!.of(Side.white, Role.knight), 1);
    lab.loadDualFen('nonsense|$start|$start');
    expect(lab.setupProblems[BoardNumber.one], 'That is not a valid dual FEN.');
  });

  test('our team is at the bottom of board 1 until the boards flip', () {
    expect(lab.bottom(BoardNumber.one), Side.white);
    expect(lab.bottom(BoardNumber.two), Side.black);
    lab.setTeam(Team.cd);
    expect(lab.bottom(BoardNumber.one), Side.black);
    lab.flip();
    expect(lab.bottom(BoardNumber.one), Side.white);
  });

  test('pointing at a move is forgotten when the table moves on', () {
    lab.preview.value = {BoardNumber.one: 'e2e4'};
    lab.play(BoardNumber.one, 'd2d4');
    expect(lab.preview.value, isNull);
  });
}
