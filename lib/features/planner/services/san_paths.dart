/// SAN move paths from the initial position, as the planner addresses the
/// positions of its walk.
library;

import 'package:dartchess/dartchess.dart';

import '../../../utils/chess_utils.dart';

/// The FEN reached by playing [path] from the initial position, or null when
/// a move in it is illegal or malformed.
String? fenAfterSanPath(List<String> path) {
  try {
    Position position = Chess.initial;
    for (final san in path) {
      final next = playSanOrNullMove(position, san);
      if (next == null) return null;
      position = next;
    }
    return position.fen;
  } catch (_) {
    // dartchess throws on unparsable SAN; the caller only needs "unplayable".
    return null;
  }
}

/// Whether [path] is [prefix] or continues it (the empty prefix matches all).
bool sanPathStartsWith(List<String> path, List<String> prefix) {
  if (prefix.length > path.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (path[i] != prefix[i]) return false;
  }
  return true;
}

/// One string per path, for keying maps by path.
String sanPathKey(List<String> path) => path.join(' ');
