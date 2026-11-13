import 'dart:io';

import 'package:chess_auto_prep/chess/bughouse/bpgn_moves.dart';
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

  test('a board steps to its move with the other board where it was then', () {
    capture();
    lab.play(BoardNumber.two, 'e2e4');
    lab.play(BoardNumber.two, 'P@d5');
    // Board 1 had made its three moves before board 2 moved.
    go(BoardNumber.two, 1);
    expect(lab.line.upto(BoardNumber.one), 3);
    go(BoardNumber.two, 2);
    // Board 1 back before its capture: board 2 had not moved yet, so its
    // drop goes with it rather than standing without a pawn.
    go(BoardNumber.one, 2);
    expect(lab.problem, isNull);
    expect(lab.line.upto(BoardNumber.one), 2);
    expect(lab.line.upto(BoardNumber.two), 0);
    expect(lab.focus, BoardNumber.one);
    // The drop brings the capture it came from.
    go(BoardNumber.two, 2);
    expect(lab.problem, isNull);
    expect(lab.line.upto(BoardNumber.one), 3);
    expect(lab.position.two.pockets!.of(Side.black, Role.pawn), 0);
  });

  test('a step is refused only when its drop has lost its capture', () {
    capture();
    lab.play(BoardNumber.two, 'e2e4');
    lab.play(BoardNumber.two, 'P@d5');
    go(BoardNumber.two, 0);
    // Board 1's capture taken out of the line: nothing gives the pawn now.
    lab.deleteFrom(lab.line.at(BoardNumber.one)!);
    expect(lab.problem, isNull);
    lab.goTo(BoardNumber.two, lab.line.lineOf(BoardNumber.two).last);
    expect((lab.problem as StepRefused).move.san, 'P@d5');
    expect(lab.line.upto(BoardNumber.two), 0);
  });

  test('with one board the arrow keys step board 1 and stop at its ends', () {
    capture();
    lab.step(-1);
    expect(lab.line.upto(BoardNumber.one), 2);
    lab.toStart();
    lab.step(-1);
    expect(lab.line.upto(BoardNumber.one), 0);
    lab.toEnd();
    expect(lab.line.upto(BoardNumber.one), 3);
  });

  group('a game on both boards', () {
    final game = File(
      'test/support/bughouse/hypebeast_v4_vs_hivemind.bpgn',
    ).readAsStringSync();

    /// How many moves each board has on it.
    (int, int) at() =>
        (lab.line.upto(BoardNumber.one), lab.line.upto(BoardNumber.two));

    setUp(() => lab.pasteMoves(game, file: 'game1.bpgn'));

    test('opens at its first move, on both boards', () {
      expect(lab.problem, isNull);
      expect(lab.single, isFalse);
      expect(at(), (0, 0));
      expect(lab.position.dualFen, TablePosition.initial.dualFen);
      expect(lab.line.of(BoardNumber.one), hasLength(48));
      expect(lab.line.of(BoardNumber.two), hasLength(52));
    });

    test('the arrow keys play it through in the order played and back', () {
      // 1A. Nf3 1a. Nf6 1B. d4 2A. g3 1b. e6
      final seen = <(int, int)>[];
      for (var i = 0; i < 5; i++) {
        lab.step(1);
        seen.add(at());
      }
      expect(seen, [(1, 0), (2, 0), (2, 1), (3, 1), (3, 2)]);
      expect(lab.focus, BoardNumber.two);
      var steps = 5;
      for (; at() != (48, 52); steps++) {
        lab.step(1);
        expect(lab.problem, isNull, reason: 'after $steps steps');
      }
      expect(steps, 100);
      lab.step(1);
      expect(at(), (48, 52));
      for (; steps > 3; steps--) {
        lab.step(-1);
        expect(lab.problem, isNull, reason: 'back to $steps');
      }
      expect(at(), (2, 1));
      lab.toEnd();
      expect(at(), (48, 52));
      lab.toStart();
      expect(at(), (0, 0));
      lab.step(-1);
      expect((at(), lab.problem), ((0, 0), null));
    });

    test('any move of either board shows the table as it was then', () {
      for (final board in BoardNumber.values) {
        for (final node in lab.line.lineOf(board)) {
          lab.goTo(board, node);
          expect(lab.problem, isNull);
          expect(lab.line.at(board), node);
          expect(
            lab.position.dualFen,
            lab.positionAfter(node)!.dualFen,
            reason: (lab.line.entry(node) as LineMove).san,
          );
        }
      }
      // 7a. N@d4 drops the knight 7B. Qxd2 took; board 2 had gone on to
      // 8B. Bb5+ by then.
      go(BoardNumber.one, 14);
      expect(lab.line.current(BoardNumber.one)!.san, 'N@d4');
      expect(lab.line.current(BoardNumber.two)!.san, 'Bb5+');
      expect(lab.line.applied.map((m) => m.san), contains('Qxd2'));
    });

    test('a board steps from either end without a refusal', () {
      lab.toEnd();
      lab.goTo(BoardNumber.two, null);
      // Board 1 is where it was when board 2 first moved: 1A. Nf3 1a. Nf6.
      expect((at(), lab.problem), ((2, 0), null));
      lab.toEnd();
      for (var i = 0; i < 52; i++) {
        lab.stepOn(BoardNumber.two, -1);
        expect(lab.problem, isNull);
      }
      expect(at(), (2, 0));
      for (var i = 0; i < 48; i++) {
        lab.stepOn(BoardNumber.one, 1);
        expect(lab.problem, isNull);
      }
      expect(lab.line.upto(BoardNumber.one), 48);
    });

    test('pasted rather than opened, it is at its end', () {
      lab
        ..newGame()
        ..showBoards(LabBoards.one)
        ..pasteMoves(game);
      expect(at(), (48, 52));
      expect(lab.single, isFalse);
    });

    test('the keys go on along a variation, then with the other board', () {
      for (var i = 0; i < 3; i++) {
        lab.step(1);
      }
      // 2A. g3 was played; a different move there is a variation.
      lab.play(BoardNumber.one, 'e2e4');
      lab.step(1);
      // Nothing follows e4 on board 1, so board 2 goes on: 1b. e6.
      expect(lab.line.current(BoardNumber.one)!.san, 'e4');
      expect(lab.line.current(BoardNumber.two)!.san, 'e6');
      lab.step(-1);
      lab.step(-1);
      expect(at(), (2, 1));
    });
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

  test('an edited board keeps the promoted mark of a piece left in place, so '
      'taking it still gives a pawn', () {
    lab.loadDualFen('r3k3/8/8/8/8/8/8/Q~3K3[] b - - 0 1');
    expect(lab.problem, isNull);
    expect(lab.position.one.board.promoted.has(Square.a1), isTrue);
    // The editor sees the board without hands or promoted marks.
    lab.editBoard(
      BoardNumber.one,
      Setup.parseFen('r3k3/8/8/8/8/8/8/Q3K3 b - - 0 1'),
    );
    expect(lab.problem, isNull);
    expect(lab.position.one.board.promoted.has(Square.a1), isTrue);
    lab.showBoards(LabBoards.two);
    lab.play(BoardNumber.one, 'a8a1');
    expect(lab.problem, isNull);
    // The queen was a pawn: C's partner D, White on board 2, gets a pawn.
    final hand = lab.position.two.pockets!;
    expect(hand.of(Side.white, Role.pawn), 1);
    expect(hand.of(Side.white, Role.queen), 0);
  });

  test('a square the editor changed loses its promoted mark', () {
    lab.loadDualFen('4k3/8/8/8/8/8/8/Q~3K3[] w - - 0 1');
    lab.editBoard(
      BoardNumber.one,
      Setup.parseFen('4k3/8/8/8/8/8/8/R3K3 w - - 0 1'),
    );
    expect(lab.problem, isNull);
    expect(lab.position.one.board.promoted.has(Square.a1), isFalse);
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
    expect(bpgnMovetext(lab.line), copied);
    expect(lab.line.upto(BoardNumber.two), 2);
    expect(lab.position.two.pockets!.of(Side.black, Role.pawn), 0);
  });

  test('a game the bughouse arena wrote opens, comments and all', () {
    // tools/bughouse_arena/match.py write_bpgn: tags, then every move with
    // its clock, the engine's score and the game time in a comment.
    lab.pasteMoves(
      '[Event "Hivemind Arena"]\n[Round "1"]\n'
      '[WhiteA "hb-v4"]\n[BlackA "hm-n1500"]\n'
      '[WhiteB "hm-n1500"]\n[BlackB "hb-v4"]\n'
      '[TimeControl "120"]\n[Opening "1e2e4 1d7d5"]\n'
      '[Result "1-0"]\n[Termination "checkmate"]\n\n'
      '1A. e4 1a. d5 2A. exd5 {[%clk 0:01:58.1] [%eval 3.19] 1.9s} '
      '1B. Nf3 {[%clk 0:01:58.0] 2.0s}\n'
      '{A-black sits @3.0s} 1b. P@e4 {[%clk 0:01:58.0] [%eval #-2] 4.0s} '
      '{A-black illegal e2e5 @4.1s} 1-0\n',
      file: 'games.bpgn',
    );
    expect(lab.problem, isNull);
    expect(lab.line.moves.map((m) => m.san), [
      'e4',
      'd5',
      'exd5',
      'Nf3',
      'P@e4',
    ]);
    // Its players and clocks are kept, and copied with the moves.
    expect(lab.game!.name(Seat.a), 'hb-v4');
    expect(lab.game!.name(Seat.c), 'hm-n1500');
    expect(
      lab.movesText,
      '[Event "Hivemind Arena"]\n[Round "1"]\n'
      '[WhiteA "hb-v4"]\n[BlackA "hm-n1500"]\n'
      '[WhiteB "hm-n1500"]\n[BlackB "hb-v4"]\n'
      '[TimeControl "120"]\n[Opening "1e2e4 1d7d5"]\n'
      '[Result "1-0"]\n[Termination "checkmate"]\n\n'
      '1A. e4 1a. d5 2A. exd5 {118.100} 1B. Nf3 {118.000} 1b. P@e4 {118.000} '
      '1-0',
    );
    // A different line from the same game no longer reached its result.
    lab.toEnd();
    lab.step(-1);
    lab.play(BoardNumber.two, 'e7e5');
    expect(lab.movesText, contains('[Result "*"]'));
    expect(lab.movesText, isNot(contains('Termination')));
    expect(lab.movesText, endsWith('1b. e5 *'));
    // Back on the game's own line, it is the game again.
    lab.stepOn(BoardNumber.two, -1);
    lab.stepOn(BoardNumber.two, 1);
    expect(lab.movesText, endsWith('{118.000} 1-0'));
    // An engine line goes without the file's clocks.
    expect(lab.linePgnWith(const []), isNot(contains(RegExp('[{}]'))));
  });

  group('a file of several games', () {
    String game(int round, String moves, {String white = 'ann'}) =>
        '[Event "Club night"]\n[Round "$round"]\n'
        '[WhiteA "$white"]\n[BlackA "cat"]\n'
        '[WhiteB "dan"]\n[BlackB "bob"]\n'
        '[TimeControl "180+0"]\n[Result "1-0"]\n\n$moves 1-0\n\n';

    final file =
        game(
          1,
          '1A. e4 {179.0} 1a. d5 {178.5} 1B. d4 {177.0} 2A. exd5 {170.2}',
        ) +
        game(2, '1A. e4 1a. Ke7', white: 'eve') +
        game(3, '1B. c4 {179.9} 1b. e5 {9.4}');

    setUp(() => lab.pasteMoves(file, file: 'night.bpgn'));

    test('opens on the first, at its start, with its players', () {
      expect((lab.gameCount, lab.gameAt), (3, 0));
      expect(lab.problem, isNull);
      expect(lab.single, isFalse);
      expect(lab.line.applied, isEmpty);
      expect(lab.line.moves, hasLength(4));
      expect(lab.game!.name(Seat.a), 'ann');
      expect(lab.game!.name(Seat.b), 'bob');
      expect(lab.game!.heading, 'A + B won · Club night · Round 1');
    });

    test('each seat\'s clock follows the boards', () {
      for (final seat in Seat.values) {
        expect(lab.timeLeft(seat), const Duration(minutes: 3));
      }
      lab.toEnd();
      expect(lab.timeLeft(Seat.a), const Duration(milliseconds: 170200));
      expect(lab.timeLeft(Seat.c), const Duration(milliseconds: 178500));
      expect(lab.timeLeft(Seat.d), const Duration(seconds: 177));
      expect(lab.timeLeft(Seat.b), const Duration(minutes: 3));
      lab.step(-1);
      expect(lab.timeLeft(Seat.a), const Duration(seconds: 179));
    });

    test('steps to another game and stops at the ends', () {
      lab.showGame(2);
      expect(lab.gameAt, 2);
      expect(lab.problem, isNull);
      expect(lab.line.moves.map((m) => m.san), ['c4', 'e5']);
      expect(lab.game!.tags['Round'], '3');
      lab.showGame(3);
      lab.showGame(-1);
      expect(lab.gameAt, 2);
    });

    test('a game that does not play is shown without moves, and named', () {
      lab.toEnd();
      lab.showGame(1);
      expect(lab.gameAt, 1);
      expect(lab.problem, isA<MovesRefused>());
      expect((lab.problem! as MovesRefused).token, '1a. Ke7');
      expect((lab.problem! as MovesRefused).file, 'night.bpgn');
      expect(lab.line.isEmpty, isTrue);
      expect(lab.position.dualFen, TablePosition.initial.dualFen);
      expect(lab.game!.name(Seat.a), 'eve');
      // The games after it are still a step away.
      lab.showGame(2);
      expect(lab.problem, isNull);
      expect(lab.line.moves, hasLength(2));
    });

    test('pasted, a first game that does not play takes nothing', () {
      lab.newGame();
      lab.play(BoardNumber.one, 'd2d4');
      lab.pasteMoves(game(2, '1A. e4 1a. Ke7') + game(3, '1B. c4 1b. e5'));
      expect((lab.problem as MovesRefused).token, '1a. Ke7');
      expect((lab.problem as MovesRefused).file, isNull);
      expect(lab.movesText, '1A. d4');
      expect(lab.gameCount, 0);
    });

    test('a new game is no game of the file', () {
      lab.newGame();
      expect((lab.gameCount, lab.game), (0, null));
      expect(lab.timeLeft(Seat.a), isNull);
    });

    test('one game pasted over it takes the file\'s place', () {
      lab.pasteMoves('1A. d4 1a. d5');
      expect((lab.gameCount, lab.game), (0, null));
      expect(lab.movesText, '1A. d4 1a. d5');
    });
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
    lab.playMoves(const [(BoardNumber.one, 'e7e8r')]);
    expect(lab.line.moves.single.san, 'e8=R+');
    lab.loadDualFen(promoting);
    lab.playMoves(const [(BoardNumber.one, 'e7e8')]);
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
