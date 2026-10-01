/// A move sequence typed into the game filter, and where a game's main line
/// plays it. Pure values; `game_filter.dart` decides which rule uses it.
///
/// The text is loose movetext: `1.e4 c5 2.Nf3`, `e4 c5 Nf3` and
/// `1. e4 c5 2. Nf3 d6` all read the same, since move numbers and results
/// are dropped. A gap marker — `…`, `...` or `..` standing on its own,
/// or the old viewer's `[gap]` — splits it into groups: each group is
/// played move after move, and the next group may come any number of plies
/// later ("anywhere after").
///
/// Example: `e4 … Nf3 d6` is in `1.e4 c5 2.Nf3 d6` (plies 0, then 2–3) and
/// in `1.e4 e5 2.d4 exd4 3.Nf3 d6`, but not in `1.Nf3 d6 2.e4`.
///
/// SAN is compared without check marks and annotation glyphs, and `0-0`
/// is `O-O`, so what someone types matches how any file spelled the move.
library;

/// The groups of one typed sequence, each a list of normalised SANs.
final class MoveSequence {
  const MoveSequence._(this.groups);

  /// [text] read as a sequence; empty groups when it names no moves.
  factory MoveSequence.parse(String text) {
    final groups = <List<String>>[];
    var group = <String>[];
    for (final token in text.replaceAll(_gapWord, ' … ').split(_space)) {
      if (token.isEmpty || _result.hasMatch(token)) continue;
      if (_gap.hasMatch(token)) {
        if (group.isNotEmpty) groups.add(List.unmodifiable(group));
        group = <String>[];
        continue;
      }
      final move = normalSan(token.replaceFirst(_moveNumber, ''));
      if (move.isNotEmpty) group.add(move);
    }
    if (group.isNotEmpty) groups.add(List.unmodifiable(group));
    return MoveSequence._(List.unmodifiable(groups));
  }

  final List<List<String>> groups;

  bool get isEmpty => groups.isEmpty;

  /// Where the sequence ends in [line], a main line of normalised SANs, or
  /// null when it is not there: the number of plies up to and including
  /// its last move, at the first place it is found. [fromStart] ties the
  /// first group to the first move; [toEnd] ties the last group to the
  /// last move.
  int? endIn(List<String> line, {bool fromStart = false, bool toEnd = false}) {
    if (isEmpty) return null;
    return _from(line, 0, 0, fromStart: fromStart, toEnd: toEnd);
  }

  /// Group [group] placed at [at] or later — exactly at [at] for the first
  /// group [fromStart] — then the rest after it.
  int? _from(
    List<String> line,
    int group,
    int at, {
    required bool fromStart,
    required bool toEnd,
  }) {
    if (group == groups.length) return toEnd && at != line.length ? null : at;
    final moves = groups[group];
    final last = fromStart && group == 0 ? at : line.length - moves.length;
    for (var start = at; start <= last; start++) {
      if (!_playsAt(line, moves, start)) continue;
      final end = _from(
        line,
        group + 1,
        start + moves.length,
        fromStart: fromStart,
        toEnd: toEnd,
      );
      if (end != null) return end;
    }
    return null;
  }

  static bool _playsAt(List<String> line, List<String> moves, int start) {
    // A sequence tied to the first move is tried there even in a game with
    // fewer moves than it has.
    if (start + moves.length > line.length) return false;
    for (var i = 0; i < moves.length; i++) {
      if (line[start + i] != moves[i]) return false;
    }
    return true;
  }

  @override
  String toString() => groups.map((group) => group.join(' ')).join(' … ');
}

/// [san] as the filter compares it: no `+`, `#`, `!` or `?`, and castling
/// spelled with letters.
String normalSan(String san) {
  final bare = san.replaceAll(_marks, '');
  return switch (bare) {
    '0-0' => 'O-O',
    '0-0-0' => 'O-O-O',
    _ => bare,
  };
}

final _space = RegExp(r'\s+');
final _gapWord = RegExp(r'\[gap\]', caseSensitive: false);
final _gap = RegExp(r'^(…|\.{2,})$');
final _moveNumber = RegExp(r'^\d+\.+');
final _result = RegExp(r'^(1-0|0-1|1/2-1/2|½-½|\*)$');
final _marks = RegExp(r'[+#!?]');
