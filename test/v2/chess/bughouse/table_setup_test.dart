import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table_setup.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

BoardBoxes boxes(String fen, {String white = '', String black = ''}) =>
    (fen: fen, white: white, black: black);

void main() {
  group('reserves', () {
    test('read as counts in any case and order', () {
      expect((parseReserve('2N q, p') as ReservePieces).letters, 'NNQP');
      expect(formatReserve('pNQn'), 'Q 2N P');
      expect(formatReserve(''), '');
    });

    test('a king or a stranger is refused in words', () {
      expect(
        (parseReserve('K') as ReserveWrong).message,
        'A king can’t be in reserve (N is the knight).',
      );
      expect(
        (parseReserve('2X') as ReserveWrong).message,
        '“X” isn’t a piece: use P, N, B, R or Q.',
      );
      expect(parseReserve('N !'), isA<ReserveWrong>());
      // A count of a billion is a typo, not a string of a billion pawns.
      expect(parseReserve('999999999P'), isA<ReserveWrong>());
    });
  });

  group('the boxes', () {
    test('fill in turn and castling a FEN leaves out', () {
      final shape =
          checkFen('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR') as FenShape;
      expect(shape.rest, 'w KQkq - 0 1');
    });

    test('say what is wrong with a FEN', () {
      expect((checkFen('') as FenWrong).message, 'Enter a FEN.');
      expect(
        (checkFen('8/8/8/8/8/8/8 w - - 0 1') as FenWrong).message,
        'A FEN has 8 ranks; this has 7.',
      );
      expect(
        (checkFen('8/8/8/8/8/8/8/8 w - - 0 1') as FenWrong).message,
        'White needs exactly one king; there are 0.',
      );
      expect(
        (checkFen('4k3/8/8/8/8/8/8/4K2X w - - 0 1') as FenWrong).message,
        '“X” isn’t a piece or a number of empty squares.',
      );
    });

    test('build a table with each player’s reserve on its board', () {
      final read = readBoxes(
        boxes(start, white: 'N'),
        boxes(start, black: '2P Q'),
      );
      final table = (read as SetupReady).position;
      expect(table.one.pockets!.of(Side.white, Role.knight), 1);
      expect(table.two.pockets!.of(Side.black, Role.pawn), 2);
      expect(table.two.pockets!.of(Side.black, Role.queen), 1);
    });

    test('name the seat whose reserve is wrong', () {
      final read = readBoxes(boxes(start), boxes(start, black: 'K'));
      final problems = (read as SetupRefused).problems;
      expect(problems.keys, [BoardNumber.two]);
      expect(problems[BoardNumber.two], startsWith('Player B: '));
    });

    test('round-trip a table through its boxes', () {
      final table =
          (readDualFen(
                    '$start|rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[Pnp] b KQkq - 0 1',
                  )
                  as SetupReady)
              .position;
      final again = readBoxes(
        boxesOf(table, BoardNumber.one),
        boxesOf(table, BoardNumber.two),
      );
      expect((again as SetupReady).position.dualFen, table.dualFen);
      expect(boxesOf(table, BoardNumber.two).black, 'N P');
    });
  });

  group('a dual FEN', () {
    test('of one FEN is board 1, with board 2 at the start', () {
      final table =
          (readDualFen('4k3/8/8/8/8/8/8/4K3 w - - 0 1') as SetupReady).position;
      expect(table.two.board, Crazyhouse.initial.board);
    });

    test('of three parts is refused', () {
      expect(
        (readDualFen('$start|$start|$start') as SetupRefused).problems.values,
        ['That is not a valid dual FEN.'],
      );
    });
  });

  group('pieces outstanding', () {
    test('none at the start', () {
      expect(
        outstanding(boxes(start), boxes(start)),
        'Pieces outstanding: none',
      );
    });

    test('counts what is missing and what is extra, promoted as pawns', () {
      final text = outstanding(
        boxes('4k3/8/8/8/8/8/8/Q~3K3 w - - 0 1'),
        boxes(start, white: '3Q'),
      );
      expect(
        text,
        'Pieces outstanding: White: 7P 2N 2B 2R · Black: 8P 2N 2B 2R 1Q'
        '   Too many: White: 2Q',
      );
    });

    test('says nothing while a FEN cannot be read', () {
      expect(outstanding(boxes('nonsense'), boxes(start)), '');
    });
  });
}
