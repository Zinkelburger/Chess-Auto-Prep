import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pv_text.dart';
import 'package:chess_auto_prep/workspace/reading/comment_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final moves = pvMoves(Fen.initial, ['e2e4', 'e7e5', 'g1f3']);
  final at = NodePath.of(const [0]);

  test('a comment line is on the board at one of its own moves', () {
    expect(CommentLine(from: at, moves: moves, at: 2).move.san, 'Nf3');
    expect(
      () => CommentLine(from: at, moves: moves, at: moves.length),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => CommentLine(from: at, moves: moves, at: -1),
      throwsA(isA<AssertionError>()),
    );
  });

  test('a move shows as on the board only in its own comment, and only the '
      'move that is', () {
    final line = CommentLine(from: at, moves: moves, at: 1);
    expect(line.shows(at, moves[1]), isTrue);
    expect(line.shows(NodePath.of(const [0, 0]), moves[1]), isFalse);
    expect(line.shows(at, moves[0]), isFalse);
    expect(line.atMove(2).shows(at, moves[2]), isTrue);
  });
}
