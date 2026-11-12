import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/document_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a compressed chapter is refused with what is wrong and that the file '
      'is left untouched', () {
    final read = readDocumentText(gzip.encode(utf8.encode('1. e4 *\n')));
    expect(
      (read as NotText).detail,
      'the file is compressed, so it is left untouched',
    );
  });

  test('a Latin-1 file reads, says it is not UTF-8 and is left untouched', () {
    final read = readDocumentText(
      latin1.encode('[White "Réti"]\n\n1. Nf3 *\n'),
    );
    expect((read as ForeignText).text, contains('Réti'));
    expect(read.detail, 'the file is not UTF-8, so it is left untouched');
  });

  List<int> ascii(String text) => latin1.encode(text);

  group('UTF-8', () {
    test('an empty file is empty text', () {
      expect((readDocumentText(const []) as PlainText).text, '');
    });

    test('keeps every byte-order mark it starts with, and adds none', () {
      const mark = [0xEF, 0xBB, 0xBF];
      expect(
        (readDocumentText([...mark, ...ascii('1. e4 *')]) as PlainText).text,
        '﻿1. e4 *',
      );
      expect(
        (readDocumentText([...mark, ...mark, ...ascii('*')]) as PlainText).text,
        '﻿﻿*',
      );
      // Characters whose UTF-8 starts like a mark but is not one.
      for (final near in ['ﺿ', '﻾', '']) {
        expect(
          (readDocumentText(utf8.encode('$near *')) as PlainText).text,
          '$near *',
          reason: near.codeUnitAt(0).toRadixString(16),
        );
      }
    });

    test('holds tabs and line breaks as text, however many', () {
      final read = readDocumentText(ascii('${'\t\n\r\n' * 200}*'));
      expect(read, isA<PlainText>());
    });
  });

  group('not text at all', () {
    test('two bytes of gzip magic are a compressed file', () {
      expect(
        (readDocumentText(const [0x1f, 0x8b]) as NotText).detail,
        'the file is compressed, so it is left untouched',
      );
    });

    test('a NUL byte anywhere in the first 8 KiB, the first included', () {
      expect(readDocumentText([0, ...ascii('1. e4 *')]), isA<NotText>());
      expect(
        readDocumentText([...ascii('a' * 1000), 0, ...ascii('*')]),
        isA<NotText>(),
      );
      expect(
        readDocumentText([...ascii('a' * 8192), 0]),
        isA<PlainText>(),
        reason: 'past what is sampled',
      );
    });

    test('control bytes refuse a file only above one in a hundred', () {
      final one = [0x1b, ...ascii('a' * 99)];
      expect(readDocumentText(one), isA<PlainText>());
      final two = [0x1b, 0x1b, ...ascii('a' * 98)];
      expect((readDocumentText(two) as NotText).detail, 'the file is not text');
    });
  });

  group('a file that is not strict UTF-8', () {
    // One byte that is never valid UTF-8 among [valid] good accented letters.
    List<int> damaged(int valid) => [
      ...utf8.encode('${'é' * valid} '),
      0xFF,
      ...ascii(' *'),
    ];

    test('keeps its UTF-8 reading with eight good letters per stray byte', () {
      final read = readDocumentText(damaged(8)) as ForeignText;
      expect(read.text, startsWith('é' * 8));
      expect(read.text, contains('�'));
    });

    test('reads as Latin-1 with fewer', () {
      final read = readDocumentText(damaged(7)) as ForeignText;
      expect(read.text, startsWith('Ã©'));
      expect(read.text, isNot(contains('�')));
    });
  });
}
