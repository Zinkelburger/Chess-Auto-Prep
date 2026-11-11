import 'package:chess_auto_prep/chess/pgn/pgn_lexer.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_token.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a header', () {
    test('a tag that ends the text is a tag', () {
      final tag = lexHeader('[Event "x"]').single as TagToken;
      expect(tag.key, 'Event');
      expect(tag.value, 'x');
    });

    test('a tag cut short before its bracket is a line, not a tag', () {
      expect(lexHeader('[Event "x"').single, isA<HeaderLineToken>());
    });

    test('a bracket with no key is a line, not a tag', () {
      expect(lexHeader('[ "x"]').single, isA<HeaderLineToken>());
    });

    test('the line after a header line starts where that line ends', () {
      final tokens = lexHeader('[junk\n[Event "x"]\n');
      expect(tokens.first, isA<HeaderLineToken>());
      expect((tokens.last as TagToken).key, 'Event');
    });
  });

  group('movetext that ends the text', () {
    test('a glyph is read', () {
      expect(lexGame('1. e4!').whereType<NagToken>().single.value, 1);
    });

    test('a run of dots is read', () {
      expect(lexGame('1. e4 2...').last, isA<MoveNumberToken>());
      expect(lexGame('1. e4 ...').last, isA<MoveNumberToken>());
    });
  });

  test('a numeric NAG reads at most four digits', () {
    expect(lexGame(r'1. e4 $12345 *').whereType<NagToken>().first.value, 1234);
  });
}
