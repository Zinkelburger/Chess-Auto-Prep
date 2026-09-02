/// Reading one line of `lichess_db_eval.jsonl`.
///
/// The published file is one JSON object per position, and it is enormous:
/// 394,669,566 lines averaging ~716 bytes, so ~283 GB of JSON once the 21.7 GB
/// `.zst` is expanded.  Handing every line to `jsonDecode` would allocate a
/// map, a list of evals and a list of PV maps per position just to keep four
/// numbers, and the import is bounded by exactly that work — so this scans the
/// text directly instead.  The shape it relies on is fixed by the publisher:
///
/// ```json
/// {"fen":"<board> <stm> <castling> <ep>",
///  "evals":[{"pvs":[{"cp":69,"line":"f7g7 e6e2 …"}, …],
///            "knodes":4189972,"depth":46}, …]}
/// ```
///
/// **Sign convention.**  `cp` and `mate` are *White-relative*, not
/// side-to-move relative.  This is not documented on the download page; it was
/// established from the data: within one eval the PVs are ordered best-first
/// for the side to move, and the `cp` sequence runs downwards for White to
/// move and upwards for Black to move (2629 vs 189 and 2395 vs 97 over a
/// 4188-line sample), which only holds for a White-relative score.  `mate`
/// agrees — `8/8/8/8/2n5/k7/2p5/KB6 b - -`, where Black mates, is published as
/// `mate: -3`.
///
/// Everything here is pure and synchronous so the importer can run it in an
/// isolate and the tests can run it on fixtures.
library;

import '../master_games/position_key.dart';

/// One position's worth of the file, reduced to what the eval store keeps.
class LichessEvalRow {
  /// FNV-1a of the 4-field FEN — the same key the master-games book uses.
  final int pos;

  /// White-relative centipawns, or null when the position is a forced mate.
  final int? cp;

  /// White-relative mate distance (negative = Black mates), or null.
  final int? mate;

  /// Search depth of the eval this row came from.
  final int depth;

  /// Best move, packed by [packUci]; 0 when the PV carried no line.
  final int move;

  const LichessEvalRow({
    required this.pos,
    required this.cp,
    required this.mate,
    required this.depth,
    required this.move,
  });
}

/// The deepest eval on one line of the file, or null when the line is blank,
/// malformed, or carries no usable score.
///
/// Ties on depth go to the eval that searched more nodes; the file lists
/// evals ordered by PV count rather than by strength, so neither position in
/// the list is meaningful on its own.
LichessEvalRow? parseLichessEvalLine(String line) {
  final fen = _extractFen(line);
  if (fen == null) return null;

  var bestDepth = -1;
  var bestKnodes = -1;
  int? bestCp;
  int? bestMate;
  var bestMove = 0;

  var i = 0;
  while (true) {
    final pvs = line.indexOf(_pvsOpen, i);
    if (pvs < 0) break;
    final pvStart = pvs + _pvsOpen.length;
    final pvEnd = line.indexOf('}', pvStart);
    if (pvEnd < 0) break;

    // `"depth"` belongs to the eval object that owns these PVs, and sits
    // after the whole `pvs` array — but so does the next eval's, so stop at
    // the next `"pvs":[{` to avoid stealing it.
    final nextPvs = line.indexOf(_pvsOpen, pvEnd);
    final depthAt = line.indexOf(_depthKey, pvEnd);
    if (depthAt < 0 || (nextPvs >= 0 && depthAt > nextPvs)) {
      i = pvEnd + 1;
      continue;
    }
    final depth = _readInt(line, depthAt + _depthKey.length);
    if (depth == null) {
      i = pvEnd + 1;
      continue;
    }
    final knodesAt = line.indexOf(_knodesKey, pvEnd);
    final knodes = (knodesAt >= 0 && (nextPvs < 0 || knodesAt < nextPvs))
        ? (_readInt(line, knodesAt + _knodesKey.length) ?? 0)
        : 0;

    if (depth > bestDepth || (depth == bestDepth && knodes > bestKnodes)) {
      final first = line.substring(pvStart, pvEnd);
      final cpAt = first.indexOf(_cpKey);
      final mateAt = first.indexOf(_mateKey);
      int? cp;
      int? mate;
      if (cpAt >= 0) {
        cp = _readInt(first, cpAt + _cpKey.length);
      } else if (mateAt >= 0) {
        mate = _readInt(first, mateAt + _mateKey.length);
      }
      // A position that is already mate carries no move and no usable score.
      if (cp == null && (mate == null || mate == 0)) {
        i = pvEnd + 1;
        continue;
      }
      bestDepth = depth;
      bestKnodes = knodes;
      bestCp = cp;
      bestMate = mate;
      bestMove = packUci(_firstLineMove(first));
    }
    i = pvEnd + 1;
  }

  if (bestDepth < 0) return null;
  return LichessEvalRow(
    pos: positionKey(fen),
    cp: bestCp,
    mate: bestMate,
    depth: bestDepth,
    move: bestMove,
  );
}

const String _fenKey = '"fen":"';
const String _pvsOpen = '"pvs":[{';
const String _depthKey = '"depth":';
const String _knodesKey = '"knodes":';
const String _cpKey = '"cp":';
const String _mateKey = '"mate":';
const String _lineKey = '"line":"';

String? _extractFen(String line) {
  final start = line.indexOf(_fenKey);
  if (start < 0) return null;
  final from = start + _fenKey.length;
  final end = line.indexOf('"', from);
  if (end <= from) return null;
  return line.substring(from, end);
}

/// The first UCI token of a PV object's `line`, or '' when it has none.
String _firstLineMove(String pvObject) {
  final at = pvObject.indexOf(_lineKey);
  if (at < 0) return '';
  final from = at + _lineKey.length;
  var end = from;
  while (end < pvObject.length) {
    final c = pvObject.codeUnitAt(end);
    if (c == 0x20 || c == 0x22) break; // space or closing quote
    end++;
  }
  return pvObject.substring(from, end);
}

/// Signed integer starting at [at], or null when there is no digit there.
int? _readInt(String s, int at) {
  var i = at;
  var negative = false;
  if (i < s.length && s.codeUnitAt(i) == 0x2d) {
    negative = true;
    i++;
  }
  var value = 0;
  var digits = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) break;
    value = value * 10 + (c - 0x30);
    digits++;
    i++;
  }
  if (digits == 0) return null;
  return negative ? -value : value;
}

// ── Move packing ─────────────────────────────────────────────────────────

const String _promoPieces = 'qrbn';

/// Pack a UCI move into 15 bits: from | to << 6 | promotion << 12.
///
/// Zero means "no move", which is why the piece codes start at 1.  Stored as
/// an integer rather than the four-character text because the column is
/// written 394 million times and SQLite spends a byte on the string header
/// plus one per character.
int packUci(String uci) {
  if (uci.length < 4 || uci.length > 5) return 0;
  final from = _square(uci, 0);
  final to = _square(uci, 2);
  if (from < 0 || to < 0) return 0;
  var promo = 0;
  if (uci.length == 5) {
    promo = _promoPieces.indexOf(uci[4].toLowerCase()) + 1;
    if (promo == 0) return 0;
  }
  return from | (to << 6) | (promo << 12);
}

/// Inverse of [packUci]; null for 0.
String? unpackUci(int packed) {
  if (packed <= 0) return null;
  final from = packed & 0x3f;
  final to = (packed >> 6) & 0x3f;
  final promo = (packed >> 12) & 0x7;
  final buf = StringBuffer()
    ..writeCharCode(0x61 + (from & 7))
    ..writeCharCode(0x31 + (from >> 3))
    ..writeCharCode(0x61 + (to & 7))
    ..writeCharCode(0x31 + (to >> 3));
  if (promo >= 1 && promo <= _promoPieces.length) {
    buf.write(_promoPieces[promo - 1]);
  }
  return buf.toString();
}

/// 0-63 for a square at [at] in [uci], or -1 when it is not one.
int _square(String uci, int at) {
  final file = uci.codeUnitAt(at) - 0x61;
  final rank = uci.codeUnitAt(at + 1) - 0x31;
  if (file < 0 || file > 7 || rank < 0 || rank > 7) return -1;
  return file | (rank << 3);
}
