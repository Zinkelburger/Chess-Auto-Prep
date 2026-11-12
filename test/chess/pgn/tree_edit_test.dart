import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1. e4, d4 and c4 as three choices at the start.
GameTree threeFirstMoves() => readGame('1. e4 (1. d4) (1. c4) *').tree!;

List<String> firstMoves(GameTree tree) => [
  for (final node in tree.children) node.san,
];

void main() {
  test('a null move passes the turn and moves the clocks on', () {
    final afterE5 = Chess.fromSetup(
      Setup.parseFen(
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 3 2',
      ),
    );
    final (_, white) = nullMovePlayed(afterE5, spelling: '--');
    expect(white.turn, Side.black);
    expect(white.halfmoves, 4);
    expect(white.fullmoves, 2);
    expect(Fen(white.fen).value, contains(' - 4 2'), reason: 'no en passant');
    final (_, black) = nullMovePlayed(white, spelling: '--');
    expect(black.fullmoves, 3);
  });

  group('promoting a variation', () {
    test('puts it first, the others keeping their order', () {
      final tree = threeFirstMoves();
      expect(firstMoves(withChildFirst(tree, const NodePath.root(), 1)), [
        'd4',
        'e4',
        'c4',
      ]);
      expect(firstMoves(withChildFirst(tree, const NodePath.root(), 2)), [
        'c4',
        'e4',
        'd4',
      ]);
    });

    test('of a move that is first, or not there, changes nothing', () {
      final tree = threeFirstMoves();
      for (final index in [-1, 0, 3]) {
        expect(firstMoves(withChildFirst(tree, const NodePath.root(), index)), [
          'e4',
          'd4',
          'c4',
        ], reason: '$index');
      }
    });
  });

  test('removing a move that is not there changes nothing', () {
    final tree = threeFirstMoves();
    for (final index in [-1, 3]) {
      expect(firstMoves(withChildRemoved(tree, const NodePath.root(), index)), [
        'e4',
        'd4',
        'c4',
      ], reason: '$index');
    }
  });

  test('changing a move that is not there changes nothing', () {
    final tree = threeFirstMoves();
    final changed = withNodeChanged(
      tree,
      NodePath.of(const [3]),
      (node) => node.copyWith(comment: 'x'),
    );
    expect(changed.children.map((n) => n.comment), everyElement(isNull));
  });
}
