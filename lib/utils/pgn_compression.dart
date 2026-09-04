/// Transparent gzip for the app's text files.
///
/// PGN is the most compressible thing the app stores — the same tag names,
/// player names and move tokens over and over. Measured on this developer's
/// own collections: a 7.1 MB player archive shrinks to 2.3 MB (31%), and a
/// repertoire with heavy annotation to 14% of its size.
///
/// Compression is detected from the file's own first two bytes, never from
/// its extension, so:
///
///   * a `.pgn` the user gzipped themselves opens normally;
///   * a `.pgn.gz` opens normally;
///   * a plain `.pgn` is untouched, at the cost of one two-byte check.
///
/// gzip rather than the stronger codecs because it is what the rest of the
/// chess world reads — Scid and `pgnscid` open `.pgn.gz` directly — and
/// because Dart has it built in with no native dependency.
library;

import 'dart:io' as io;
import 'dart:typed_data';

/// The gzip magic number, RFC 1952 §2.3.1.
const int _gzipMagic0 = 0x1f;
const int _gzipMagic1 = 0x8b;

/// Whether [bytes] look like a gzip member.
///
/// Two bytes is enough to be sure in practice: no PGN starts with 0x1f, which
/// is a control character, and a real PGN begins with `[`, a digit, a comment
/// or whitespace.
bool looksGzipped(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == _gzipMagic0 && bytes[1] == _gzipMagic1;

/// Decompress [bytes] when they are gzipped, otherwise return them unchanged.
///
/// A corrupt gzip stream returns the bytes as-is rather than throwing: the
/// caller's decoder will then fail on obvious garbage, which is a better error
/// than an opaque one from deep inside the codec.
List<int> maybeGunzip(List<int> bytes) {
  if (!looksGzipped(bytes)) return bytes;
  try {
    return io.gzip.decode(bytes);
  } catch (_) {
    return bytes;
  }
}

/// gzip [bytes] at the given [level] (1 fastest … 9 smallest, 6 default).
Uint8List gzipBytes(List<int> bytes, {int level = 6}) =>
    Uint8List.fromList(io.GZipCodec(level: level).encode(bytes));

/// How much a file would save by being compressed, as a fraction in [0, 1].
///
/// Returns 0 when the file is already compressed or would not shrink.
double compressionSavingOf(List<int> raw, Uint8List compressed) {
  if (raw.isEmpty || compressed.length >= raw.length) return 0;
  return 1 - compressed.length / raw.length;
}
