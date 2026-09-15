/// Streaming, encoding-tolerant line reader for large text files.
///
/// A multi-gigabyte PGN database is never resident: bytes are read in fixed
/// chunks, decoded incrementally, split into lines, and each line is handed
/// over as soon as it is complete.  The previous whole-file
/// `readAsBytesSync` → decode → `split('\n')` held three copies of the file
/// at once (bytes, a two-byte-per-char string, and a list of every line).
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

/// Bytes read per `readIntoSync`.  Large enough that the syscall count is
/// irrelevant, small enough that three of them (raw, decoded, carry) are
/// nothing next to whatever the caller is building from the lines.
const int _readChunkBytes = 4 << 20;

/// Feed every line of the file at [path] to [onLine], without its `\n`.
///
/// Encoding follows `decodeTextBytesDetailed`: UTF-8, with a whole-file
/// Latin-1 fallback when the bytes are not valid UTF-8.  A validation pass
/// decides that up front — lines are consumed as they stream and cannot be
/// un-consumed if a malformed byte turns up late in the file.  Returns
/// whether the fallback was used.
bool readTextLines(String path, void Function(String line) onLine) {
  final file = io.File(path).openSync();
  try {
    final utf8Valid = isValidUtf8(file);
    file.setPositionSync(0);

    final lines = _LineSink(onLine);
    final ByteConversionSink decoder = utf8Valid
        ? utf8.decoder.startChunkedConversion(lines)
        : latin1.decoder.startChunkedConversion(lines);
    final buffer = Uint8List(_readChunkBytes);
    while (true) {
      final read = file.readIntoSync(buffer);
      if (read == 0) break;
      decoder.addSlice(buffer, 0, read, false);
    }
    decoder.close();
    return !utf8Valid;
  } finally {
    file.closeSync();
  }
}

/// Whether [file] (read from its current position to the end) is well-formed
/// UTF-8, by the same rules `utf8.decode` enforces: no overlong forms, no
/// surrogates, nothing above U+10FFFF.  Streams the bytes; allocates nothing
/// per byte.  Leaves the file positioned at its end.
bool isValidUtf8(io.RandomAccessFile file) {
  final buffer = Uint8List(_readChunkBytes);
  var pending = 0; // Continuation bytes still expected.
  var low = 0x80; // Allowed range of the next continuation byte.
  var high = 0xBF;
  while (true) {
    final read = file.readIntoSync(buffer);
    if (read == 0) break;
    for (var i = 0; i < read; i++) {
      final b = buffer[i];
      if (pending > 0) {
        if (b < low || b > high) return false;
        low = 0x80;
        high = 0xBF;
        pending--;
      } else if (b < 0x80) {
        continue;
      } else if (b >= 0xC2 && b <= 0xDF) {
        pending = 1;
      } else if (b == 0xE0) {
        pending = 2;
        low = 0xA0;
      } else if (b == 0xED) {
        pending = 2;
        high = 0x9F;
      } else if (b >= 0xE1 && b <= 0xEF) {
        pending = 2;
      } else if (b == 0xF0) {
        pending = 3;
        low = 0x90;
      } else if (b == 0xF4) {
        pending = 3;
        high = 0x8F;
      } else if (b >= 0xF1 && b <= 0xF3) {
        pending = 3;
      } else {
        return false;
      }
    }
  }
  return pending == 0;
}

/// Turns decoded text chunks into lines.  Only the trailing partial line is
/// carried between chunks, so memory stays bounded by the longest line.
class _LineSink implements Sink<String> {
  _LineSink(this._onLine);

  final void Function(String line) _onLine;
  String _carry = '';

  @override
  void add(String chunk) {
    var start = 0;
    while (true) {
      final newline = chunk.indexOf('\n', start);
      if (newline < 0) break;
      final line = chunk.substring(start, newline);
      _onLine(_carry.isEmpty ? line : _carry + line);
      _carry = '';
      start = newline + 1;
    }
    if (start < chunk.length) _carry += chunk.substring(start);
  }

  @override
  void close() {
    if (_carry.isNotEmpty) _onLine(_carry);
    _carry = '';
  }
}
