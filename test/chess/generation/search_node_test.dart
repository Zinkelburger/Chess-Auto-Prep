import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:flutter_test/flutter_test.dart';

Fen _board(String name) => Fen('$name w - - 0 1');

SearchNode _horizon(String name) =>
    HorizonNode(fen: _board(name), evalForUs: const Eval(0));

/// Our move at [name], one candidate leading to [child].
SearchNode _ours(String name, SearchNode child) => OurNode.over(
  fen: _board(name),
  evalForUs: const Eval(0),
  candidates: [
    CandidateMove(
      move: MoveRef(uci: name, san: name),
      child: child,
    ),
  ],
);

void main() {
  group('searched to a depth', () {
    test('a tree whose horizon is that deep is searched to it, not past', () {
      final tree = _ours('a', _ours('b', _horizon('c')));
      expect(searchedTo(tree, 2), isTrue);
      expect(searchedTo(tree, 3), isFalse);
    });

    test('a position left unexpanded short of the depth is not', () {
      final tree = _ours(
        'a',
        const FrontierNode(fen: Fen('b w - - 0 1'), evalForUs: Eval(0)),
      );
      expect(searchedTo(tree, 1), isTrue);
      expect(searchedTo(tree, 2), isFalse);
    });

    test('a finished game is searched as deep as asked', () {
      final tree = _ours(
        'a',
        TerminalNode(
          fen: _board('mate'),
          evalForUs: const Eval(0),
          kind: TerminalKind.checkmate,
          ourTurn: false,
        ),
      );
      expect(searchedTo(tree, 10), isTrue);
    });
  });
}
