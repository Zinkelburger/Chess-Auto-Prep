/// Scid's home-pawn record: which pawns left their starting squares, in
/// order, as the index stores it (`mainlineInfo`, `src/game.cpp`).
///
/// A 16-bit signature starts with every home square set — one bit per
/// square, **set while the pawn is still there** — and bits clear as pawns
/// leave or are captured.  After each mainline move the difference
/// `old - new` names the square that changed, and the value recorded is that
/// difference's highest set bit *position*: `15 - index`, where index is 0-7
/// for White a-h and 8-15 for Black a-h.
///
/// Tracked for the mainline only, and only from the standard start: from a
/// FEN there is no "home" to leave, and Scid leaves the count at zero.
library;

import 'dart:typed_data';

import 'package:dartchess/dartchess.dart';

class ScidHomePawnTracker {
  /// A tracker that records nothing when [enabled] is false (a game that
  /// starts from a FEN).
  ScidHomePawnTracker({this.enabled = true});

  final bool enabled;

  /// Scid keeps at most sixteen departures — one per pawn.
  static const int maxDepartures = 16;

  /// The record is nine bytes: the count, then the departures as nibbles.
  static const int recordBytes = 9;

  static const int _allHome = 0xFFFF;
  int _signature = _allHome;
  final List<int> _departures = [];

  /// Departures recorded so far.
  int get count => _departures.length;

  /// The departures in order, each `15 - index` as described above.
  List<int> get departures => List.unmodifiable(_departures);

  /// Record the pawn, if any, that left its home square in the move that
  /// produced [after].
  void noteMove(Position after) {
    if (!enabled) return;
    final now = signatureOf(after);
    final changed = _signature - now;
    if (changed <= 0) return;
    _signature = now;
    if (_departures.length < maxDepartures) {
      _departures.add(changed.bitLength - 1);
    }
  }

  /// The nine-byte record: the count, then up to sixteen nibbles with the
  /// first departure in the HIGH nibble of the first byte.
  Uint8List toBytes() {
    final out = Uint8List(recordBytes);
    out[0] = _departures.length;
    for (var i = 0; i < _departures.length; i++) {
      final v = _departures[i] & 0x0F;
      out[1 + (i >> 1)] |= i.isEven ? v << 4 : v;
    }
    return out;
  }

  /// The signature of [position]: a bit set for every home square still
  /// holding its own pawn.
  static int signatureOf(Position position) {
    var sig = 0;
    for (var file = 0; file < 8; file++) {
      final white = position.board.pieceAt(Square(8 + file));
      if (white != null &&
          white.role == Role.pawn &&
          white.color == Side.white) {
        sig |= 1 << (15 - file);
      }
      final black = position.board.pieceAt(Square(48 + file));
      if (black != null &&
          black.role == Role.pawn &&
          black.color == Side.black) {
        sig |= 1 << (15 - (8 + file));
      }
    }
    return sig;
  }
}
