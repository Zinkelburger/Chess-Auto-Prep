import 'dart:convert';

import 'package:chess_auto_prep/utils/file_text_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodeTextBytesDetailed', () {
    test('decodes valid UTF-8 unchanged', () {
      final bytes = utf8.encode('Hello échecs');
      final result = decodeTextBytesDetailed(bytes);
      expect(result.text, 'Hello échecs');
      expect(result.usedLatin1Fallback, isFalse);
    });

    test('a few stray bytes in a UTF-8 file do not turn it into Latin-1', () {
      // A course export: megabytes of UTF-8 prose with four control bytes
      // from a broken FEN tag. Read as Latin-1 every curly quote broke.
      final bytes = [
        ...utf8.encode('It’s White’s move — ' * 50),
        0xee,
        0xee,
        ...utf8.encode('StartFEN'),
        0xee,
        0xee,
        ...utf8.encode(' rnbqkbnr'),
      ];
      final result = decodeTextBytesDetailed(bytes);
      expect(result.usedLatin1Fallback, isFalse);
      expect(result.text, startsWith('It’s White’s move — '));
      expect(result.text, contains('\uFFFD\uFFFDStartFEN\uFFFD\uFFFD'));
    });

    test('falls back to Latin-1 for invalid UTF-8 bytes', () {
      // 0xed is invalid as a lone UTF-8 byte but is Latin-1 "í" (Hoyvík).
      final bytes = [...utf8.encode('Site "Hoyv'), 0xed, ...utf8.encode('k"')];
      final result = decodeTextBytesDetailed(bytes);
      expect(result.text, 'Site "Hoyvík"');
      expect(result.usedLatin1Fallback, isTrue);
    });
  });
}
