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

/// Their move at [name]: one reply played [share] of the time, the rest
/// going to a position searched as deep as anyone asks.
SearchNode _theirs(String name, double share, SearchNode child) =>
    OpponentNode.over(
      fen: _board(name),
      evalForUs: const Eval(0),
      replies: [
        ReplyMove(
          move: const MoveRef(uci: 'rare', san: 'rare'),
          probability: share,
          child: child,
        ),
        ReplyMove(
          move: const MoveRef(uci: 'usual', san: 'usual'),
          probability: 1 - share,
          child: TerminalNode(
            fen: _board('over'),
            evalForUs: const Eval(0),
            kind: TerminalKind.checkmate,
            ourTurn: false,
          ),
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

    test('a reply too rare to prepare for is searched at any depth', () {
      final tree = _ours('a', _theirs('b', 0.005, _horizon('c')));
      expect(searchedTo(tree, 5), isFalse);
      expect(searchedTo(tree, 5, replyFloor: 0.01), isTrue);
    });

    test('a horizon games reach often enough is still a cut', () {
      final tree = _ours('a', _theirs('b', 0.02, _horizon('c')));
      expect(searchedTo(tree, 5, replyFloor: 0.01), isFalse);
      // Two replies of one in fifty, one after the other, are under it.
      final deeper = _ours(
        'a',
        _theirs('b', 0.02, _ours('c', _theirs('d', 0.02, _horizon('e')))),
      );
      expect(searchedTo(deeper, 9, replyFloor: 0.01), isTrue);
    });

    test('a rare position never looked at is not searched', () {
      final tree = _ours(
        'a',
        _theirs(
          'b',
          0.005,
          const FrontierNode(fen: Fen('c w - - 0 1'), evalForUs: null),
        ),
      );
      expect(searchedTo(tree, 5, replyFloor: 0.01), isFalse);
    });
  });
}
