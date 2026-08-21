import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/utils/pgn_utils.dart';

/// PGN tag values escape backslash and double-quote, and the order matters:
/// doubling backslashes after escaping quotes would corrupt the quote escapes.
void main() {
  group('escapeHeaderValue', () {
    test('leaves an ordinary value alone', () {
      expect(escapeHeaderValue('Fischer, R'), 'Fischer, R');
    });

    test('escapes a double quote', () {
      expect(escapeHeaderValue('The "Immortal"'), r'The \"Immortal\"');
    });

    test('escapes a backslash', () {
      expect(escapeHeaderValue(r'C:\games'), r'C:\\games');
    });

    test('does not double-escape the backslash it just wrote for a quote', () {
      // Quote-first ordering would yield `\\"` here, which reads back as a
      // literal backslash followed by an unescaped quote — a broken tag.
      expect(escapeHeaderValue('say "hi"'), r'say \"hi\"');
    });

    test('handles a backslash immediately before a quote', () {
      expect(escapeHeaderValue(r'a\"b'), r'a\\\"b');
    });
  });
}
