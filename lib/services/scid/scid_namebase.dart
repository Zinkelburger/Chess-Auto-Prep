/// The SCID5 name file (`.sn5`) — every distinct player, event, site and round
/// stored once, with the index records referring to them by id.
///
/// The format (`src/codec_scid5.h:104-112`) is an append-only sequence with no
/// header: each entry is `varint(length * 8 + type)` followed by the raw
/// bytes. Ids are sequential from 0 **per type**, in first-use order.
///
/// This is where the name deduplication comes from that makes Scid's storage
/// so much tighter than a row-per-game table: 1.9M TWIC games carry 124 MB of
/// repeated player/event/site text that dedupes to 2 MB.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Entry types, matching `nameT` in `src/namebase.h:35-38`.
class ScidNameType {
  const ScidNameType._();
  static const int player = 0;
  static const int event = 1;
  static const int site = 2;
  static const int round = 3;

  /// Database description and flag labels.
  static const int dbInfo = 4;
}

/// Accumulates names, assigns ids, and emits the `.sn5` bytes.
class ScidNameBase {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final List<Map<String, int>> _ids = [
    <String, int>{}, // player
    <String, int>{}, // event
    <String, int>{}, // site
    <String, int>{}, // round
  ];
  final List<int> _next = [0, 0, 0, 0];

  /// Scid's per-type ceilings (`src/codec_scid5.h:167-172`).
  static const int maxPlayerOrEvent = 1 << 28;
  static const int maxRound = 1 << 31;

  /// The id for [name] of [type], appending it on first use.
  int idFor(int type, String name) {
    final table = _ids[type];
    final existing = table[name];
    if (existing != null) return existing;

    final id = _next[type]++;
    table[name] = id;
    _append(type, name);
    return id;
  }

  /// Add a database-info entry (description, flag labels). Not id-addressed.
  void addDbInfo(String value) => _append(ScidNameType.dbInfo, value);

  void _append(int type, String value) {
    // Capped at 255 bytes (Scid's own limit), and a name may not contain a
    // NUL - the reader treats it as a terminator elsewhere.
    var data = utf8.encode(_stripNul(value));
    if (data.length > 255) data = data.sublist(0, 255);
    _writeVarint(data.length * 8 + type);
    _bytes.add(data);
  }

  static String _stripNul(String v) => v.codeUnits.contains(0)
      ? String.fromCharCodes(v.codeUnits.where((c) => c != 0))
      : v;

  /// LEB128, low seven bits first with the high bit as the continuation flag.
  void _writeVarint(int value) {
    var v = value;
    while (v >= 0x80) {
      _bytes.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    _bytes.addByte(v);
  }

  /// Distinct names recorded for [type].
  int countOf(int type) => _next[type];

  Uint8List toBytes() => _bytes.toBytes();
}
