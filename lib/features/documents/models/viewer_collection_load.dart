import '../../../models/pgn_game_entry.dart';

/// A decoder transfers these fresh game entries to the receiving document.
/// Collection membership is fixed; the document owns subsequent game edits.
class DecodedPgnCollection {
  DecodedPgnCollection(Iterable<PgnGameEntry> games, this.preamble)
    : games = List.unmodifiable(games);
  final List<PgnGameEntry> games;
  final String preamble;
}
