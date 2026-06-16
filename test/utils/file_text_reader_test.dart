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

    test('falls back to Latin-1 for invalid UTF-8 bytes', () {
      // 0xed is invalid as a lone UTF-8 byte but is Latin-1 "í" (Hoyvík).
      final bytes = [...utf8.encode('Site "Hoyv'), 0xed, ...utf8.encode('k"')];
      final result = decodeTextBytesDetailed(bytes);
      expect(result.text, 'Site "Hoyvík"');
      expect(result.usedLatin1Fallback, isTrue);
    });
  });
}
