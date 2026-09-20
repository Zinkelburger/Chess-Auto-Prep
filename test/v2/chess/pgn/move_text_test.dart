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
}
