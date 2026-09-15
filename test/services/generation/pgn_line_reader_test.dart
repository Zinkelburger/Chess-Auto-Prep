import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/services/generation/pgn_line_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('pgn_line_reader'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  List<String> linesOf(String path, {bool? expectLatin1}) {
    final lines = <String>[];
    final usedLatin1 = readTextLines(path, lines.add);
    if (expectLatin1 != null) expect(usedLatin1, expectLatin1);
    return lines;
  }

  group('readTextLines', () {
    test('splits on newlines and keeps an unterminated last line', () {
      final path = write('plain.pgn', utf8.encode('[A "1"]\n\n1. e4\nlast'));
      expect(linesOf(path, expectLatin1: false), [
        '[A "1"]',
        '',
        '1. e4',
        'last',
      ]);
    });

    test('keeps a carriage return for the caller to trim', () {
      final path = write('crlf.pgn', utf8.encode('a\r\nb\r\n'));
      expect(linesOf(path), ['a\r', 'b\r']);
    });

    test('decodes valid UTF-8 as UTF-8', () {
      final path = write('utf8.pgn', utf8.encode('[White "Ünal Ærø"]\n'));
      expect(linesOf(path, expectLatin1: false), ['[White "Ünal Ærø"]']);
    });

    test('falls back to Latin-1 for the whole file on one bad byte', () {
      final path = write(
        'latin1.pgn',
        latin1.encode('[White "Müller"]\n[Black "Ægir"]\n'),
      );
      expect(linesOf(path, expectLatin1: true), [
        '[White "Müller"]',
        '[Black "Ægir"]',
      ]);
    });

    test('an empty file yields no lines', () {
      final path = write('empty.pgn', const []);
      expect(linesOf(path, expectLatin1: false), isEmpty);
    });
  });

  group('isValidUtf8', () {
    bool valid(List<int> bytes) {
      final file = File(write('probe.bin', bytes)).openSync();
      try {
        return isValidUtf8(file);
      } finally {
        file.closeSync();
      }
    }

    test('accepts ASCII and well-formed multi-byte sequences', () {
      expect(valid(utf8.encode('plain ascii')), isTrue);
      expect(valid(utf8.encode('ü € 😀')), isTrue);
    });

    test('rejects what utf8.decode rejects', () {
      expect(valid([0xC3]), isFalse, reason: 'truncated sequence');
      expect(valid([0xC0, 0x80]), isFalse, reason: 'overlong form');
      expect(valid([0xED, 0xA0, 0x80]), isFalse, reason: 'UTF-16 surrogate');
      expect(
        valid([0xF4, 0x90, 0x80, 0x80]),
        isFalse,
        reason: 'above U+10FFFF',
      );
      expect(valid([0x80]), isFalse, reason: 'stray continuation byte');
    });
  });
}
