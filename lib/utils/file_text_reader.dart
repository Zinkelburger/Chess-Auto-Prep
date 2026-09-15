/// Reading the app's text files: encoding fallback, and transparent gzip.
///
/// Every PGN the app opens comes through here, which is why gzip is handled
/// at this one point rather than at 22 call sites — see [maybeGunzip] for why
/// detection is by magic bytes rather than by file extension.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'pgn_compression.dart';

/// Files at least this large are decoded off the calling isolate.
const int _offloadDecodeBytes = 256 * 1024;

/// Decoded text plus whether strict UTF-8 had to be abandoned for Latin-1.
class TextDecodeResult {
  final String text;
  final bool usedLatin1Fallback;

  const TextDecodeResult({required this.text, this.usedLatin1Fallback = false});
}

/// Reads [file] as text, gunzipping when its bytes say so.
Future<String> readTextFile(File file) async {
  final bytes = await file.readAsBytes();
  // Decompression and text decoding are CPU work even after an async read.
  // A small gzip can expand to a large library, so always offload gzip.
  if (looksGzipped(bytes) || bytes.length >= _offloadDecodeBytes) {
    return Isolate.run(() => decodeTextBytes(maybeGunzip(bytes)));
  }
  return decodeTextBytes(bytes);
}

/// [readTextFile] for callers that cannot await.
String readTextFileSync(File file) =>
    decodeTextBytes(maybeGunzip(file.readAsBytesSync()));

/// The text in [bytes]; see [decodeTextBytesDetailed] for the encoding rule.
String decodeTextBytes(List<int> bytes) => decodeTextBytesDetailed(bytes).text;

/// A file that fails strict UTF-8 is read one of two ways. A Latin-1 file
/// fails on its very first accented letter and has no valid multi-byte
/// sequence anywhere; a UTF-8 file with a few damaged bytes (a course export
/// with four control bytes in ten megabytes of curly quotes) has thousands.
/// The second used to be read as Latin-1 wholesale, turning every quote in
/// it into mojibake. So: keep the UTF-8 reading, stray bytes as U+FFFD, when
/// valid non-ASCII characters outnumber the strays by this factor.
const int _validToStrayRatio = 8;

TextDecodeResult decodeTextBytesDetailed(List<int> bytes) {
  try {
    return TextDecodeResult(text: utf8.decode(bytes));
  } on FormatException {
    final tolerant = utf8.decode(bytes, allowMalformed: true);
    var strays = 0;
    var valid = 0;
    for (final unit in tolerant.codeUnits) {
      if (unit == 0xFFFD) {
        strays++;
      } else if (unit > 0x7F) {
        valid++;
      }
    }
    if (valid >= strays * _validToStrayRatio) {
      return TextDecodeResult(text: tolerant);
    }
    return TextDecodeResult(
      text: latin1.decode(bytes),
      usedLatin1Fallback: true,
    );
  }
}
