import 'dart:convert';

/// The move names the network scores, and where each one sits in its output.
///
/// The names are standard UCI as Stockfish and Lichess write them: castling
/// is the king's own destination (`e1g1`, never the king-onto-rook `e1h1`),
/// and a promotion carries its piece (`e7e8q`). The shipped table is the
/// 64×64 from-to grid plus White's promotions, 4352 entries, which is all the
/// network needs: it only ever sees White to move, so a Black promotion
/// reaches it through the mirror.
final class MaiaVocabulary {
  const MaiaVocabulary._(this._indices, this._names);

  /// The table as `all_moves_maia3.json` holds it: `{"a1a1": 0, ...}`.
  ///
  /// Null when [text] is not that. A build whose asset is damaged has no
  /// opponent model at all, which is better than one that reads a move's
  /// probability off somebody else's index.
  static MaiaVocabulary? parse(String text) {
    final Object? decoded = _decode(text);
    if (decoded is! Map<String, Object?>) return null;
    final indices = <String, int>{};
    var highest = -1;
    for (final MapEntry(:key, :value) in decoded.entries) {
      if (value is! int || value < 0) return null;
      indices[key] = value;
      if (value > highest) highest = value;
    }
    if (indices.isEmpty) return null;
    final names = List.filled(highest + 1, '');
    for (final MapEntry(:key, :value) in indices.entries) {
      names[value] = key;
    }
    return MaiaVocabulary._(indices, names);
  }

  static Object? _decode(String text) {
    try {
      return json.decode(text);
    } on FormatException {
      return null;
    }
  }

  final Map<String, int> _indices;
  final List<String> _names;

  /// How wide the network's move output is.
  int get size => _names.length;

  /// Where [uci] is scored, or null for a move the table does not name.
  int? indexOf(String uci) => _indices[uci];

  /// The move scored at [index], or the empty string when nothing is.
  String nameAt(int index) =>
      index >= 0 && index < _names.length ? _names[index] : '';
}
