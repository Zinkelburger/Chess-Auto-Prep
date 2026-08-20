/// Compression of stored movetext.
///
/// SAN movetext is ~525 bytes a game and two million games of it is the
/// biggest thing in `master_games.db`.  zlib alone takes it to ~300 bytes;
/// zlib with a preset dictionary — a few hundred real games' worth of
/// movetext, so the common opening sequences and move tokens are already in
/// the window — to ~225 bytes, at ~0.05 ms a game.  A binary move encoding
/// would get to ~90 bytes but needs a full-game replay on import, which
/// doubles import time for 140 bytes a game; not worth it.
///
/// The dictionary is data, not code: the importer builds it from the first
/// issue it stores and keeps it in the `meta` table, so every reader — this
/// class, the Python MCP tools — takes it from the database and nothing has
/// to stay in sync across tools or versions.  An empty dictionary is plain
/// zlib, so a database without one still decodes.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// `meta` key under which the dictionary bytes live.
const String kMovetextDictKey = 'movetext_dict';

/// Dictionary size: zlib's window is 32 KiB, so more is never used.
const int kMovetextDictBytes = 32768;

class MovetextCodec {
  final ZLibEncoder _enc;
  final ZLibDecoder _dec;

  /// The dictionary in use (empty = plain zlib).
  final Uint8List dictionary;

  MovetextCodec(List<int> dictionary)
    : dictionary = Uint8List.fromList(dictionary),
      _enc = ZLibEncoder(
        level: 9,
        dictionary: dictionary.isEmpty ? null : dictionary,
      ),
      _dec = ZLibDecoder(dictionary: dictionary.isEmpty ? null : dictionary);

  static final MovetextCodec plain = MovetextCodec(const []);

  Uint8List encode(String movetext) =>
      Uint8List.fromList(_enc.convert(utf8.encode(movetext)));

  String decode(List<int> blob) => utf8.decode(_dec.convert(blob));

  /// A dictionary from a sample of movetexts: their concatenation, cut to
  /// [kMovetextDictBytes].  zlib matches against the *end* of the
  /// dictionary most cheaply, so the sample order does not matter much;
  /// what matters is that it is real movetext.
  static Uint8List buildDictionary(Iterable<String> movetexts) {
    final b = BytesBuilder(copy: false);
    for (final m in movetexts) {
      if (b.length >= kMovetextDictBytes) break;
      b.add(utf8.encode(m));
      b.addByte(0x20);
    }
    final all = b.takeBytes();
    return all.length <= kMovetextDictBytes
        ? all
        : Uint8List.sublistView(all, 0, kMovetextDictBytes);
  }
}
