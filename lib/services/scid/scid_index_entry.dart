/// The fixed-size index record Scid keeps per game.
///
/// SCID5 (`.si5`) is 56 bytes: twelve little-endian `uint32` followed by eight
/// bytes of home-pawn data. The bit fields inside each word run **high bits
/// first**, in the order `src/codec_scid5.h:60-90` lists them — that ordering
/// was confirmed against a reference database Scid itself wrote (a 2751 Elo, a
/// 2021.08.17 date and a 61-ply count all decode correctly out of it).
///
/// A `.si5` file is nothing but these records: no header, no magic. The
/// database's description and flags live in the namebase as `dbInfo` entries.
library;

import 'dart:typed_data';

/// Scid's result codes (`src/common.h:90-93`).
class ScidResult {
  const ScidResult._();
  static const int none = 0;
  static const int white = 1;
  static const int black = 2;
  static const int draw = 3;

  /// Map a PGN `Result` tag.
  static int fromPgn(String? result) => switch (result?.trim()) {
    '1-0' => white,
    '0-1' => black,
    '1/2-1/2' => draw,
    _ => none,
  };
}

/// Pack a date the way Scid does: `(year << 9) | (month << 5) | day`
/// (`src/date.h:40-48`). Zero means "no date"; a partial date simply leaves
/// the missing components at zero, which is what Scid stores too.
int scidDate(String? pgnDate) {
  if (pgnDate == null) return 0;
  final parts = pgnDate.split('.');
  int part(int i) {
    if (i >= parts.length) return 0;
    return int.tryParse(parts[i]) ?? 0;
  }

  final year = part(0);
  if (year <= 0 || year > 2047) return 0;
  final month = part(1).clamp(0, 15);
  final day = part(2).clamp(0, 31);
  return (year << 9) | (month << 5) | day;
}

/// Pack an ECO code (`src/misc.cpp:36-60`).
///
/// Numbering: none = 0, `A00` = 1, and each basic code is the previous plus
/// 131 — the gap holds Scid's 130 extended sub-codes (`A00a`, `A00a1`, …).
int scidEco(String? eco) {
  if (eco == null || eco.isEmpty) return 0;
  final s = eco.trim();
  if (s.isEmpty) return 0;
  final c = s.codeUnitAt(0);
  int base;
  if (c >= 0x41 && c <= 0x45) {
    base = (c - 0x41) * 13100; // 'A'..'E'
  } else if (c >= 0x61 && c <= 0x65) {
    base = (c - 0x61) * 13100; // 'a'..'e'
  } else {
    return 0;
  }
  if (s.length < 2) return base + 1;
  final d1 = s.codeUnitAt(1) - 0x30;
  if (d1 < 0 || d1 > 9) return 0;
  base += d1 * 1310;
  if (s.length < 3) return base + 1;
  final d2 = s.codeUnitAt(2) - 0x30;
  if (d2 < 0 || d2 > 9) return base + 1;
  base += d2 * 131;
  return base + 1;
}

/// Scid buckets annotation counts into 4 bits, rounding to the nearest of
/// 0-10, 15, 20, 30, 40, 50 (`src/codec_scid5.h:92-101`).
int scidCountRating(int count) {
  const steps = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 20, 30, 40, 50];
  var best = 0;
  var bestDelta = (count - steps[0]).abs();
  for (var i = 1; i < steps.length; i++) {
    final d = (count - steps[i]).abs();
    if (d < bestDelta) {
      bestDelta = d;
      best = i;
    }
  }
  return best;
}

/// Everything one `.si5` record holds.
class ScidIndexEntry {
  const ScidIndexEntry({
    required this.whiteId,
    required this.blackId,
    required this.eventId,
    required this.siteId,
    required this.roundId,
    required this.whiteElo,
    required this.blackElo,
    required this.date,
    required this.eventDate,
    required this.plyCount,
    required this.dataLength,
    required this.dataOffset,
    required this.finalMaterial,
    required this.homePawnData,
    required this.homePawnCount,
    required this.result,
    required this.eco,
    this.commentRating = 0,
    this.variationRating = 0,
    this.nagRating = 0,
    this.flags = 0,
    this.chess960 = false,
    this.storedLineCode = 0,
    this.whiteEloType = 0,
    this.blackEloType = 0,
  });

  final int whiteId;
  final int blackId;
  final int eventId;
  final int siteId;
  final int roundId;
  final int whiteElo;
  final int blackElo;
  final int date;
  final int eventDate;
  final int plyCount;
  final int dataLength;
  final int dataOffset;
  final int finalMaterial;
  final Uint8List homePawnData;
  final int homePawnCount;
  final int result;
  final int eco;
  final int commentRating;
  final int variationRating;
  final int nagRating;
  final int flags;
  final bool chess960;

  /// Index flag bits (`src/indexentry.h:260-262`). Scid sets PROMO for any
  /// promotion and UPROMO *in addition* for a non-queen one.
  static const int flagOwnStart = 1 << 0;
  static const int flagPromotions = 1 << 1;
  static const int flagUnderPromo = 1 << 2;
  static const int flagDeleted = 1 << 3;

  /// The flag word a game with these properties gets.
  static int flagsFor({
    required bool ownStart,
    required bool promotions,
    required bool underPromotions,
  }) =>
      (ownStart ? flagOwnStart : 0) |
      (promotions ? flagPromotions : 0) |
      (underPromotions ? flagUnderPromo : 0);

  /// 0 means "not classified", which Scid reads as "this game might reach any
  /// position, check it properly" — the safe value for a writer that does not
  /// carry Scid's 255-line opening table.
  final int storedLineCode;

  final int whiteEloType;
  final int blackEloType;

  static const int recordSizeV5 = 56;

  /// Serialise as a SCID5 record.
  Uint8List toBytesV5() {
    final out = Uint8List(recordSizeV5);
    final view = ByteData.sublistView(out);
    var w = 0;
    void word(int value) {
      view.setUint32(w, value & 0xFFFFFFFF, Endian.little);
      w += 4;
    }

    int hi(int high, int highBits, int low) =>
        ((high & ((1 << highBits) - 1)) << (32 - highBits)) |
        (low & ((1 << (32 - highBits)) - 1));

    word(hi(commentRating, 4, whiteId));
    word(hi(variationRating, 4, blackId));
    word(hi(nagRating, 4, eventId));
    word(siteId);
    word(hi(chess960 ? 1 : 0, 1, roundId));
    word(hi(whiteElo, 12, date));
    word(hi(blackElo, 12, eventDate));
    word(hi(plyCount, 10, flags));
    word(hi(dataLength, 17, dataOffset >> 32));
    word(dataOffset & 0xFFFFFFFF);
    word(hi(storedLineCode, 8, finalMaterial));
    // 8 home-pawn count | 3 white type | 3 black type | 2 result | 16 eco
    final tail =
        ((homePawnCount & 0xFF) << 24) |
        ((whiteEloType & 0x7) << 21) |
        ((blackEloType & 0x7) << 18) |
        ((result & 0x3) << 16) |
        (eco & 0xFFFF);
    word(tail);

    // The final eight bytes are the home-pawn data; Scid stores nine bytes
    // (a count plus sixteen nibbles) but the record only carries the nibbles,
    // the count having its own field above.
    for (var i = 0; i < 8; i++) {
      out[48 + i] = i + 1 < homePawnData.length ? homePawnData[i + 1] : 0;
    }
    return out;
  }
}
