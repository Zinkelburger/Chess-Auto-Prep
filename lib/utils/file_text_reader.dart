/// Reading the app's text files: encoding fallback, and transparent gzip.
///
/// Every PGN the app opens comes through here, which is why gzip is handled
/// at this one point rather than at 22 call sites — see [maybeGunzip] for why
/// detection is by magic bytes rather than by file extension.
library;

import 'dart:convert';
import 'dart:io';

import 'pgn_compression.dart';

class TextDecodeResult {
  final String text;
  final bool usedLatin1Fallback;

  const TextDecodeResult({required this.text, this.usedLatin1Fallback = false});
}

Future<String> readTextFile(File file) async {
  return decodeTextBytes(maybeGunzip(await file.readAsBytes()));
}

String readTextFileSync(File file) {
  return decodeTextBytes(maybeGunzip(file.readAsBytesSync()));
}

String decodeTextBytes(List<int> bytes) {
  return decodeTextBytesDetailed(bytes).text;
}

TextDecodeResult decodeTextBytesDetailed(List<int> bytes) {
  try {
    return TextDecodeResult(text: utf8.decode(bytes));
  } on FormatException {
    return TextDecodeResult(
      text: latin1.decode(bytes),
      usedLatin1Fallback: true,
    );
  }
}
