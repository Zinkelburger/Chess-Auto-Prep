import 'package:chess_auto_prep/chess/pgn/comment_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prose replaces the words of a comment and keeps its tokens', () {
    expect(withProse(null, ''), isNull);
    expect(withProse(null, ' Hi '), 'Hi');
    expect(withProse('[%clk 0:01:00]', ''), '[%clk 0:01:00]');
    expect(withProse('old [%clk 0:01:00]', 'new'), 'new [%clk 0:01:00]');
  });

  test('each NAG a reader knows has its glyph, and no other does', () {
    const glyphs = {
      1: '!',
      2: '?',
      3: '!!',
      4: '??',
      5: '!?',
      6: '?!',
      10: '=',
      13: '∞',
      14: '⩲',
      15: '⩱',
      16: '±',
      17: '∓',
      18: '+−',
      19: '−+',
    };
    for (var nag = 0; nag <= 20; nag++) {
      expect(nagGlyph(nag), glyphs[nag], reason: '\$$nag');
    }
  });
}
