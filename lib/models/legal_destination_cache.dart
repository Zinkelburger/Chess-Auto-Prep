/// Legal moves and the FENs they lead to, memoised for the positions an
/// opening-tree cursor has visited most recently.
library;

import 'dart:collection';

import 'package:dartchess/dartchess.dart';

import '../utils/chess_utils.dart' show tryParseFen;

/// A legal move from a position together with the FEN it produces.
///
/// The SAN is not part of this record on purpose: producing it costs a second
/// move generation in dartchess (`makeSan` runs checkmate detection on the
/// child), and the one-ply transposition scan only needs it for the one or
/// two moves that actually land in the book.
typedef LegalDestination = ({Move move, String fen});

/// A parsed position and every legal move out of it.
typedef LegalDestinationEntry = ({
  Position position,
  List<LegalDestination> destinations,
});

/// Legal moves and their destination FENs for a handful of recently visited
/// positions.  Pure in the FEN, so it never needs invalidating; bounded so an
/// hour of browsing cannot pin every visited position's move list.
class LegalDestinationCache {
  LegalDestinationCache({this.capacity = defaultCapacity});

  static const int defaultCapacity = 32;

  /// Positions kept before the least recently used one is dropped.
  final int capacity;
  final LinkedHashMap<String, LegalDestinationEntry> _entries = LinkedHashMap();

  /// Number of positions currently held.
  int get length => _entries.length;

  /// The entry for [fen], computed on first sight and refreshed to most
  /// recently used on every hit.  Null when [fen] does not parse.
  LegalDestinationEntry? lookup(String fen) {
    final hit = _entries.remove(fen);
    if (hit != null) {
      _entries[fen] = hit; // Refresh recency.
      return hit;
    }
    final position = tryParseFen(fen);
    if (position == null) return null;
    final entry = (position: position, destinations: destinationsOf(position));
    _entries[fen] = entry;
    if (_entries.length > capacity) _entries.remove(_entries.keys.first);
    return entry;
  }

  /// Every legal move (promotions as four entries) with the FEN after it.
  /// Moves come from [Position.legalMoves], so [Position.playUnchecked] is
  /// safe and skips a second legality check per move.
  static List<LegalDestination> destinationsOf(Position position) {
    final out = <LegalDestination>[];
    for (final entry in position.legalMoves.entries) {
      final from = entry.key;
      final piece = position.board.pieceAt(from);
      final promotes =
          piece != null &&
          piece.role == Role.pawn &&
          ((piece.color == Side.white && from.rank == Rank.seventh) ||
              (piece.color == Side.black && from.rank == Rank.second));
      for (final to in entry.value.squares) {
        if (promotes && (to.rank == Rank.eighth || to.rank == Rank.first)) {
          for (final role in const [
            Role.queen,
            Role.knight,
            Role.rook,
            Role.bishop,
          ]) {
            final move = NormalMove(from: from, to: to, promotion: role);
            out.add((move: move, fen: position.playUnchecked(move).fen));
          }
        } else {
          final move = NormalMove(from: from, to: to);
          out.add((move: move, fen: position.playUnchecked(move).fen));
        }
      }
    }
    return out;
  }
}
