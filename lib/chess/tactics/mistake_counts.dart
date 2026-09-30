import 'dart:convert';

import 'analyzed_games.dart' show analyzedGamesPrefix;
import 'puzzle.dart' show MistakeKind;

/// How many of the user's moves in one game the review marked `??`, `?`
/// and `?!`: every move it judged, including those that made no puzzle
/// because the engine had no line to learn or the position was one the set
/// already had.
final class MistakeCounts {
  const MistakeCounts({
    this.blunders = 0,
    this.mistakes = 0,
    this.inaccuracies = 0,
  });

  final int blunders;
  final int mistakes;
  final int inaccuracies;

  /// These counts with one more move of [kind].
  MistakeCounts plus(MistakeKind kind) => MistakeCounts(
    blunders: blunders + (kind == MistakeKind.blunder ? 1 : 0),
    mistakes: mistakes + (kind == MistakeKind.mistake ? 1 : 0),
    inaccuracies: inaccuracies + (kind == MistakeKind.inaccuracy ? 1 : 0),
  );

  /// `1?? 2?`, as a game's row prints them: only the kinds the game has,
  /// and `clean` for a game with none.
  String get glyphs {
    final marks = [
      if (blunders > 0) '$blunders??',
      if (mistakes > 0) '$mistakes?',
      if (inaccuracies > 0) '$inaccuracies?!',
    ];
    return marks.isEmpty ? 'clean' : marks.join(' ');
  }

  /// `1 blunder, 2 inaccuracies`, or `No mistakes`.
  String get words {
    final said = [
      for (final (n, kind) in [
        (blunders, MistakeKind.blunder),
        (mistakes, MistakeKind.mistake),
        (inaccuracies, MistakeKind.inaccuracy),
      ])
        if (n > 0) '$n ${n == 1 ? kind.word : kind.plural}',
    ];
    return said.isEmpty ? 'No mistakes' : said.join(', ');
  }

  List<int> get _json => [blunders, mistakes, inaccuracies];

  @override
  bool operator ==(Object other) =>
      other is MistakeCounts &&
      other.blunders == blunders &&
      other.mistakes == mistakes &&
      other.inaccuracies == inaccuracies;

  @override
  int get hashCode => Object.hash(blunders, mistakes, inaccuracies);
}

/// The counts live in the tactics set beside the analysed-games line, so a
/// game's puzzles, its done mark and its counts are one write:
///
/// ```
/// ; ChessAutoPrep-Analyzed-v1: WyJsaWNoZXNzX0FiQ2QxMjM0Il0=
/// ; ChessAutoPrep-Mistakes-v1: eyJsaWNoZXNzX0FiQ2QxMjM0IjpbMSwyLDBdfQ==
/// ```
///
/// The second line is a JSON object from game id to `[blunders, mistakes,
/// inaccuracies]`, keys sorted, UTF-8, base64url. It is never the first
/// line, which the old app reads as its own and nothing else. The counts
/// are derived: a line that cannot be read is no counts, never a refusal.
const mistakeCountsPrefix = '; ChessAutoPrep-Mistakes-v1: ';

/// The counts the set's [preamble] holds, by game id; empty when it holds
/// none or the line cannot be read.
Map<String, MistakeCounts> mistakesIn(String preamble) {
  final line = _lineOf(preamble);
  if (line == null) return const {};
  final Object? decoded;
  try {
    decoded = jsonDecode(
      utf8.decode(
        base64Url.decode(line.substring(mistakeCountsPrefix.length).trim()),
      ),
    );
  } on Object {
    return const {};
  }
  if (decoded is! Map) return const {};
  return {
    for (final MapEntry(:key, :value) in decoded.entries)
      if (key is String &&
          value is List &&
          value.length == 3 &&
          value.every((n) => n is int && n >= 0))
        key: MistakeCounts(
          blunders: value[0] as int,
          mistakes: value[1] as int,
          inaccuracies: value[2] as int,
        ),
  };
}

/// [preamble] with its counts line holding [counts] as well as what it held:
/// replaced where it is, or put right after the analysed-games line.
String withMistakes(String preamble, Map<String, MistakeCounts> counts) {
  if (counts.isEmpty) return preamble;
  final all = {...mistakesIn(preamble), ...counts};
  final keys = all.keys.toList()..sort();
  final line =
      '$mistakeCountsPrefix'
      '${base64Url.encode(utf8.encode(jsonEncode({for (final id in keys) id: all[id]!._json})))}';
  final lines = preamble.split('\n');
  final at = lines.indexWhere((l) => l.startsWith(mistakeCountsPrefix));
  if (at >= 0) {
    lines[at] = line;
  } else {
    lines.insert(lines.first.startsWith(analyzedGamesPrefix) ? 1 : 0, line);
  }
  return lines.join('\n');
}

String? _lineOf(String preamble) {
  for (final line in preamble.split('\n')) {
    if (line.startsWith(mistakeCountsPrefix)) return line;
  }
  return null;
}
