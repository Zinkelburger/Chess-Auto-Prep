/// Stable 64-bit key for a chess position, used as the primary key of the
/// master-games `book` table.
///
/// The key is FNV-1a over the 4-field canonical FEN ([canonicalizeFen4]), so
/// two move orders reaching the same position share a key, and the key can be
/// recomputed by any other tool (the Python MCP side) from the FEN alone —
/// no Zobrist table to keep in sync.  Dart VM ints are 64-bit and wrap on
/// multiply, which is exactly FNV's arithmetic.
library;

import '../eval/eval_canonicalize.dart';

const int _fnvOffset = -3750763034362895579; // 0xcbf29ce484222325 as signed
const int _fnvPrime = 1099511628211;

/// 64-bit signed FNV-1a of the canonical 4-field FEN of [fen].
int positionKey(String fen) {
  final s = canonicalizeFen4(fen);
  var h = _fnvOffset;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h *= _fnvPrime;
  }
  return h;
}
