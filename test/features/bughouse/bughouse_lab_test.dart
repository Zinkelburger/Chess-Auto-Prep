import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/chess/bughouse/table_line.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:dartchess/dartchess.dart' show Role, Setup, Side, Square;
import 'package:flutter_test/flutter_test.dart';

const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void main() {
  late BughouseLab lab;

  setUp(() => lab = BughouseLab());
  tearDown(() => lab.dispose());

  /// [board] at its [count]th move along its line.
  void go(BoardNumber board, int count) {
    final moves = [
      for (final n in lab.line.lineOf(board))
        if (lab.line.entry(n) is LineMove) n,
    ];
    lab.goTo(board, count == 0 ? null : moves[count - 1]);
  }

  /// The hand edit [board] is at, as the list writes it.
  String editHere(BoardNumber board) =>
      handChangeText((lab.line.entry(lab.line.at(board)!) as HandEdit).changes);

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
    go(BoardNumber.two, 1);
    expect(lab.line.upto(BoardNumber.one), 3);
    go(BoardNumber.two, 2);
    go(BoardNumber.one, 2);
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

  test('a new game or a pasted position starts a new line', () {
    capture();
    lab.newGame();
    expect(lab.line.moves, isEmpty);
    lab.loadDualFen('$start|$start');
    expect(lab.problem, isNull);
    lab.loadDualFen('nonsense|$start|$start');
    expect(
      (lab.problem as PositionRefused).reason,
      'That is not a valid dual FEN.',
    );
  });

  test('+ and − change a hand and keep the moves before it', () {
    capture();
    lab.adjustHand(BoardNumber.one, Side.black, Role.knight, 1);
    expect(lab.position.one.pockets!.of(Side.black, Role.knight), 1);
    expect(lab.line.moves.map((m) => m.san), ['e4', 'd5', 'exd5']);
    expect(lab.line.upto(BoardNumber.one), 3);
    expect(lab.position.two.pockets!.of(Side.black, Role.pawn), 1);
    expect(editHere(BoardNumber.one), '+n');
    lab.adjustHand(BoardNumber.one, Side.black, Role.knight, -1);
    expect(lab.line.nodes.where((n) => n.entry is HandEdit), isEmpty);
    lab.adjustHand(BoardNumber.one, Side.black, Role.knight, -1);
    expect(lab.position.one.pockets!.of(Side.black, Role.knight), 0);
    for (var i = 0; i < handLimit + 2; i++) {
      lab.adjustHand(BoardNumber.two, Side.white, Role.queen, 1);
    }
    expect(lab.position.two.pockets!.of(Side.white, Role.queen), handLimit);
    expect(editHere(BoardNumber.two), '+16Q');
  });

  test('a hand edit is a step of its own; one made where the board goes on '
      'is a variation', () {
    lab.play(BoardNumber.one, 'e2e4');
    lab.adjustHand(BoardNumber.one, Side.black, Role.knight, 2);
    lab.adjustHand(BoardNumber.one, Side.white, Role.pawn, 1);
    lab.play(BoardNumber.one, 'N@f6');
    expect(lab.position.one.pockets!.of(Side.black, Role.knight), 1);
    go(BoardNumber.one, 1);
    expect(lab.position.one.pockets!.of(Side.black, Role.knight), 0);
    lab.stepOn(BoardNumber.one, 1);
    expect(lab.position.one.pockets!.of(Side.black, Role.knight), 2);
    expect(editHere(BoardNumber.one), '+P +2n');
    lab.adjustHand(BoardNumber.one, Side.black, Role.queen, 1);
    expect(lab.line.moves.map((m) => m.san), ['e4', 'N@f6']);
    expect(lab.line.of(BoardNumber.one).map((m) => m.san), ['e4']);
    expect(lab.position.one.pockets!.of(Side.black, Role.queen), 1);
  });

  test('a different move is a variation the list can promote', () {
    lab.play(BoardNumber.one, 'e2e4');
    lab.play(BoardNumber.one, 'e7e5');
    lab.step(-1);
    lab.play(BoardNumber.one, 'c7c5');
    final c5 = lab.line.at(BoardNumber.one)!;
    expect(lab.line.moves.map((m) => m.san), ['e4', 'e5', 'c5']);
    expect(lab.line.isMain(c5), isFalse);
    // Forward from e4 follows the main line, as in the workspace.
    lab.step(-1);
    lab.step(1);
    expect(lab.line.current(BoardNumber.one)!.san, 'e5');
    lab.promote(c5);
    expect(lab.line.isMain(c5), isTrue);
    lab.toStart();
    lab.toEnd();
    expect(lab.line.current(BoardNumber.one)!.san, 'c5');
  });

  test('hand edits copy as comments and paste back', () {
    lab.adjustHand(BoardNumber.one, Side.white, Role.rook, 1);
    capture();
    lab.adjustHand(BoardNumber.one, Side.black, Role.knight, 1);
    lab.adjustHand(BoardNumber.one, Side.black, Role.knight, 1);
    // Board 2's Black has the pawn board 1 took, and gives it up.
    lab.adjustHand(BoardNumber.two, Side.black, Role.pawn, -1);
    lab.play(BoardNumber.one, 'N@f6');
    final copied = lab.movesText;
    expect(
      copied,
      '{ Hands edited on board 1: +R } 1A. e4 1a. d5 2A. exd5\n'
      '{ Hands edited on board 1: +2n } { Hands edited on board 2: −p } '
      '2a. N@f6',
    );
    lab.newGame();
    lab.pasteMoves(copied);
    expect(lab.problem, isNull);
    expect(lab.movesText, copied);
    expect(lab.position.one.pockets!.of(Side.black, Role.knight), 1);
    expect(lab.position.one.pockets!.of(Side.white, Role.rook), 1);
    expect(lab.position.two.pockets!.of(Side.black, Role.pawn), 0);
  });

  test('an edited board keeps its hands; one that cannot play is refused', () {
    lab.adjustHand(BoardNumber.one, Side.white, Role.rook, 1);
    lab.editBoard(
      BoardNumber.one,
      Setup.parseFen('4k3/8/8/8/8/8/8/4K3 b - - 0 1'),
    );
    expect(lab.problem, isNull);
    expect(lab.position.one.turn, Side.black);
    expect(lab.position.one.pockets!.of(Side.white, Role.rook), 1);
    lab.editBoard(
      BoardNumber.one,
      Setup.parseFen('8/8/8/8/8/8/8/4K3 w - - 0 1'),
    );
    expect(lab.problem, isA<PositionRefused>());
    expect(lab.position.one.board.kingOf(Side.black), isNotNull);
  });

  test('one board shown steps board 1', () {
    lab.showBoards(LabBoards.two);
    lab.play(BoardNumber.two, 'e2e4');
    expect(lab.focus, BoardNumber.two);
    lab.showBoards(LabBoards.one);
    expect(lab.single, isTrue);
    expect(lab.focus, BoardNumber.one);
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
    expect(
      copied,
      startsWith(
        '[SetUpDualFEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR/ b',
      ),
    );
    lab.newGame();
    lab.pasteMoves(copied);
    expect(lab.movesText, copied);
  });

  test('an underpromotion plays, copies and pastes back as itself', () {
    const promoting = 'k7/4P3/8/8/8/8/8/K7[] w - - 0 1';
    lab.loadDualFen(promoting);
    lab.play(BoardNumber.one, 'e7e8n');
    expect(lab.line.moves.single.san, 'e8=N');
    expect(lab.position.one.board.pieceAt(Square.e8)?.role, Role.knight);
    final copied = lab.movesText;
    lab.newGame();
    lab.pasteMoves(copied);
    expect(lab.problem, isNull);
    expect(lab.line.moves.single.san, 'e8=N');
    // An engine's move names its piece too; a bare one is a queen.
    lab.loadDualFen(promoting);
    lab.playJoint(const JointMove('e7e8r', null));
    expect(lab.line.moves.single.san, 'e8=R+');
    lab.loadDualFen(promoting);
    lab.playJoint(const JointMove('e7e8', null));
    expect(lab.line.moves.single.san, 'e8=Q+');
  });

  test('an engine line plays up to a move, all or nothing', () {
    lab.playMoves(const [
      (BoardNumber.one, 'e2e4'),
      (BoardNumber.two, 'd2d4'),
      (BoardNumber.one, 'e7e5'),
    ]);
    expect(lab.line.moves.map((m) => m.san), ['e4', 'd4', 'e5']);
    lab.playMoves(const [(BoardNumber.one, 'g1f3'), (BoardNumber.one, 'a1a8')]);
    expect(lab.problem, isA<LineMisfits>());
    expect(lab.line.moves.length, 3);
  });

  test('delete from here takes the move and its board’s later moves', () {
    capture();
    lab.play(BoardNumber.two, 'e2e4');
    lab.deleteFrom(lab.line.lineOf(BoardNumber.one)[1]);
    expect(lab.line.of(BoardNumber.one).map((m) => m.san), ['e4']);
    expect(lab.line.of(BoardNumber.two).single.san, 'e4');
    // The capture board 2 dropped cannot go.
    lab.newGame();
    capture();
    lab.play(BoardNumber.two, 'e2e4');
    lab.play(BoardNumber.two, 'P@d5');
    final before = lab.line;
    lab.deleteFrom(lab.line.lineOf(BoardNumber.one)[2]);
    expect((lab.problem as DeleteRefused).move.san, 'P@d5');
    expect(lab.line, same(before));
  });

  test('a move copies its line, its FEN and the table after it', () {
    lab.showBoards(LabBoards.two);
    lab.play(BoardNumber.one, 'e2e4');
    lab.play(BoardNumber.two, 'd2d4');
    lab.play(BoardNumber.one, 'e7e5');
    final e4 = lab.line.lineOf(BoardNumber.one).first;
    expect(lab.linePgnThrough(e4), '1A. e4');
    final d4 = lab.line.lineOf(BoardNumber.two).single;
    expect(lab.linePgnThrough(d4), '1A. e4 1B. d4');
    expect(lab.positionAfter(e4)!.one.fen, startsWith('rnbqkbnr/pppppppp/8'));
    expect(lab.positionAfter(d4)!.two.turn, Side.black);
    lab.showBoards(LabBoards.one);
    expect(
      lab.linePgnThrough(lab.line.lineOf(BoardNumber.one).last),
      '[Variant "Crazyhouse"]\n\n1. e4 e5 *',
    );
  });

  test('an engine line copies after the moves on the boards', () {
    lab.play(BoardNumber.one, 'e2e4');
    lab.play(BoardNumber.one, 'e7e5');
    go(BoardNumber.one, 1);
    expect(
      lab.linePgnWith(const [
        (BoardNumber.one, 'c7c5'),
        (BoardNumber.one, 'g1f3'),
        (BoardNumber.one, 'a1a8'),
      ]),
      '[Variant "Crazyhouse"]\n\n1. e4 c5 2. Nf3 *',
    );
  });
}
