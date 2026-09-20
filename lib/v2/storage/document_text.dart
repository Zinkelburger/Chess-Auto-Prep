/// Reading a file's bytes as a document, or refusing them.
///
/// One place, because the store must read a file exactly as it will write it
/// back: a byte string this decides is a document is a byte string a save may
/// replace.
library;

import 'dart:convert';

/// What a file holds: a document, or a reason this app will not treat it as
/// one. Never a document made out of bytes that are not text.
sealed class DocumentText {
  const DocumentText();
}

final class PlainText extends DocumentText {
  const PlainText(this.text);

  final String text;
}

final class NotText extends DocumentText {
  const NotText(this.detail);

  /// For the log and for the user; the widget writes the sentence around it.
  final String detail;
}

/// A gzipped chapter, which the old app writes and reads by the two magic
/// bytes of RFC 1952 rather than by extension.
const _compressed =
    'this chapter is compressed; open and save it in the old app to '
    'store it uncompressed';

const _notText = 'the file is not text';

/// Control bytes per byte read at which a file stops being text. Tab, line
/// feed and carriage return are text; a stray escape or two in a course
/// export is not enough to refuse the file.
const _controlLimit = 0.01;

/// How much of a file is looked at to decide whether it is text at all.
const _sampled = 8192;

/// Valid non-ASCII characters per stray byte for a file to keep its UTF-8
/// reading. The old app's number, and both apps must read one file the same
/// way.
const _validToStrayRatio = 8;

/// The text in [bytes], read as the old app reads the same files, so every
/// PGN it opens opens here too. Whatever came in, a save writes UTF-8 back.
///
/// Bytes that are not text at all are refused rather than decoded: a
/// gzipped chapter read as Latin-1 would open as mojibake and the first save
/// would replace it with bytes neither app could read.
///
/// Otherwise strict UTF-8 first. A file that fails it is one of two things. A
/// Latin-1 file fails on its first accented letter and holds no valid
/// multi-byte sequence anywhere, so it is decoded as Latin-1. A UTF-8 file
/// with a few damaged bytes among thousands of good ones — a course export
/// with four control bytes in ten megabytes of curly quotes — keeps its UTF-8
/// reading with the stray bytes as U+FFFD, because reading it as Latin-1
/// would turn every one of those quotes into mojibake.
DocumentText readDocumentText(List<int> bytes) {
  final refusal = _binary(bytes);
  if (refusal != null) return NotText(refusal);
  return PlainText(_decode(bytes));
}

/// Why [bytes] are not a text document, or null when they could be one.
String? _binary(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    return _compressed;
  }
  final sample = bytes.length < _sampled ? bytes.length : _sampled;
  var controls = 0;
  for (var i = 0; i < sample; i++) {
    final byte = bytes[i];
    if (byte == 0) return _notText;
    if (byte < 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) controls++;
  }
  return controls > sample * _controlLimit ? _notText : null;
}

String _decode(List<int> bytes) {
  try {
    return utf8.decode(bytes);
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
    return valid >= strays * _validToStrayRatio
        ? tolerant
        : latin1.decode(bytes);
  }
}
