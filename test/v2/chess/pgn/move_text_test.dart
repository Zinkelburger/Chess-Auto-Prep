import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/move_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// [movetext] read and written again, which is what a chapter does to the
/// one game an edit touched.
String rewritten(String movetext) =>
    writeMoveText(readGame(movetext).tree!, terminator: '*');

void main() {
  test('a brace inside a comment is text and survives the trip', () {
    expect(rewritten('1. e4 {see {this} *'), '1. e4 {see {this} *');
  });

  test('a comment written before a move is written before it again', () {
    expect(
      rewritten('1. e4 ({A note} 1. d4 d5) e5 *'),
      '1. e4 ({A note} 1. d4 d5) e5 *',
    );
  });

  test('a comment keeps its machine tokens and its NAGs keep their move', () {
    expect(
      rewritten(r'1. d4 d5 2. c4 e6 $6 {[%eval 0.21]} *'),
      r'1. d4 d5 2. c4 e6 $6 {[%eval 0.21]} *',
    );
  });

  test('a line is copied as bare moves to the move it ends on', () {
    final tree = readGame(
      '1. e4 {main} e5 (1... c5 \$1 {Sicilian} 2. Nf3 d6 3. d4) 2. Nf3 *',
    ).tree!;
    expect(writeLineTo(tree, NodePath.of([0, 1, 0])), '1. e4 c5 2. Nf3 *');
    expect(writeLineTo(tree, NodePath.of([0, 1])), '1. e4 c5 *');
  });

  test('a line from another position carries its FEN', () {
    const fen = 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
    final tree = readGame('[SetUp "1"]\n[FEN "$fen"]\n\n2. Nf3 Nc6 *').tree!;
    expect(
      writeLineTo(tree, NodePath.of([0, 0])),
      '[SetUp "1"]\n[FEN "$fen"]\n\n2. Nf3 Nc6 *',
    );
  });
}
