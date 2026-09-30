import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
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
    expect(lab.problem, isA<DropRefused>());
    lab.play(BoardNumber.one, 'e7e5');
    final notOnMove = lab.problem as NotOnMove;
    expect((notOnMove.side, notOnMove.board), (Side.black, BoardNumber.one));
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
    expect((lab.problem as StepRefused).move.san, 'P@d5');
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
    expect(lab.problem, isA<LineMisfits>());
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

  test('A + B is at the bottom of both boards until they flip', () {
    expect(lab.bottom(BoardNumber.one), Side.white);
    expect(lab.bottom(BoardNumber.two), Side.black);
    lab.flip();
    expect(lab.bottom(BoardNumber.one), Side.black);
    expect(lab.bottom(BoardNumber.two), Side.white);
  });

  test('pointing at a move is forgotten when the table moves on', () {
    lab.preview.value = {BoardNumber.one: 'e2e4'};
    lab.play(BoardNumber.one, 'd2d4');
    expect(lab.preview.value, isNull);
  });

  test('both boards\' moves copy in the order played and paste back', () {
    capture();
    lab.play(BoardNumber.two, 'e2e4');
    lab.play(BoardNumber.two, 'P@d5');
    expect(lab.movesText, '1A. e4 1a. d5 2A. exd5 1B. e4 1b. P@d5');
    final copied = lab.movesText;
    lab.newGame();
    lab.pasteMoves('[Event "FICS"]\n$copied {a comment} 1-0');
    expect(lab.problem, isNull);
    expect(lab.movesText, copied);
    expect(lab.line.upto(BoardNumber.two), 2);
    expect(lab.position.two.pockets!.of(Side.black, Role.pawn), 0);
  });

  test('pasted moves that do not play change nothing and say which', () {
    lab.play(BoardNumber.one, 'e2e4');
    lab.pasteMoves('1A. e4 1B. P@d5');
    expect((lab.problem as MovesRefused).token, '1B. P@d5');
    expect(lab.movesText, '1A. e4');
    lab.pasteMoves('hello');
    expect((lab.problem as MovesRefused).token, isNull);
  });

  test('a line from a set-up table copies with its dual FEN', () {
    lab.loadDualFen(
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1|$start',
    );
    expect(lab.problem, isNull);
    lab.play(BoardNumber.two, 'd2d4');
    final copied = lab.movesText;
    expect(copied, startsWith('[SetUpDualFEN "'));
    lab.newGame();
    lab.pasteMoves(copied);
    expect(lab.movesText, copied);
  });
}
