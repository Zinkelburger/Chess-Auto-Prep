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
}
