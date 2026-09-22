import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/chess_core/pgn/move_text_writer.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/models/move_tree_pgn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('writeMoveText', () {
    test('numbers White moves and only the first Black move', () {
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      expect(
        writeMoveText(
          roots: tree.roots,
          startMoveNumber: 1,
          startIsWhite: true,
        ),
        '1. e4 e5 2. Nf3',
      );
    });

    test('a line starting with Black to move numbers its first move', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      final tree = MoveTree.fromMoves(['c5', 'Nf3'], startingFen: fen);
      expect(tree.toPgnMoveText(), '1... c5 2. Nf3');
    });

    test('writes variations in parentheses after the mainline move', () {
      final tree = MoveTree.fromPgn('1. e4 e5 (1... c5 2. Nf3 d6) 2. Nf3');
      expect(tree.toPgnMoveText(), '1. e4 e5 (1... c5 2. Nf3 d6 ) 2. Nf3');
    });

    test('writes starting comments, NAGs and comments around each move', () {
      final tree = MoveTree.fromMoves(['e4', 'e5']);
      tree.rootComment = 'Open games';
      tree.roots[0]
        ..nags = [1]
        ..comment = 'best by test';
      tree.roots[0].children[0].startingComment = 'classical';
      expect(
        tree.toPgnMoveText(),
        '{Open games} 1. e4 \$1 {best by test} {classical} e5',
      );
    });

    test('strips braces from comments so they cannot break the block', () {
      expect(sanitizePgnComment('a {b} c'), 'a b c');
    });
  });

  group('MoveTreePgnCodec.joinComments', () {
    test('joins the trimmed non-empty blocks with one space', () {
      expect(MoveTreePgnCodec.joinComments([' a ', '', 'b']), 'a b');
    });

    test('is null when there is nothing to keep', () {
      expect(MoveTreePgnCodec.joinComments(null), isNull);
      expect(MoveTreePgnCodec.joinComments(['  ', '']), isNull);
    });
  });

  group('MoveTreePgnCodec.nodesFromDartchess', () {
    test('drops a subtree whose move is illegal from its parent', () {
      final game = PgnGame.parsePgn('1. e4 (1. e9 e5) e5 2. Nf3');
      final roots = MoveTreePgnCodec.nodesFromDartchess(
        game.moves.children,
        Chess.initial,
      );
      expect(roots.map((n) => n.san), ['e4']);
      expect(roots[0].children.map((n) => n.san), ['e5']);
      expect(roots[0].children[0].children.map((n) => n.san), ['Nf3']);
    });
  });
}
