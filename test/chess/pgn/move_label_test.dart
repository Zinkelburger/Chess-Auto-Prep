import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/move_label.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:flutter_test/flutter_test.dart';

GameTree tree(String moves) => readGame('$moves *').tree!;

void main() {
  final ruy = tree('1. e4 e5 (1... c5) 2. Nf3 Nc6 3. Bb5');

  group('moves from the start', () {
    test('follow the main line, numbered, as far as asked', () {
      expect(movesFrom(ruy, plies: 5), '1.e4 e5 2.Nf3 Nc6 3.Bb5');
      expect(movesFrom(ruy, plies: 9), '1.e4 e5 2.Nf3 Nc6 3.Bb5');
    });

    test('end in … where the line goes on', () {
      expect(movesFrom(ruy, plies: 3), '1.e4 e5 2.Nf3 …');
    });

    test('begin with … past the moves skipped, numbered where they start', () {
      expect(movesFrom(ruy, plies: 2, skip: 1), '…1...e5 2.Nf3 …');
      expect(movesFrom(ruy, plies: 2, skip: 2), '…2.Nf3 Nc6 …');
    });

    test('of a tree with no moves are nothing', () {
      expect(movesFrom(tree(''), plies: 3), '');
    });
  });

  group('a continuation', () {
    final e4 = ruy.children.first;

    test('numbers its first move as a line does and ends in … where the line '
        'goes on', () {
      expect(continuation(e4, plies: 2), '1...e5 2.Nf3 …');
    });

    test('ends without … at the end of the line', () {
      expect(continuation(e4, plies: 9), '1...e5 2.Nf3 Nc6 3.Bb5');
      expect(continuation(ruy.mainLine.last, plies: 3), '');
    });
  });
}
