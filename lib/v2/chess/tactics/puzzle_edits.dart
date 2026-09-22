import '../pgn/chapter.dart';
import '../pgn/chapter_edit.dart';
import '../pgn/chapter_line.dart';
import '../pgn/game_text.dart';
import '../pgn/games_written.dart';
import '../pgn/rewrite_gate.dart';
import 'puzzle.dart';

/// Writing how a puzzle went back into its game's headers: pure functions
/// from one set [Chapter] to the next, each rewriting the one game it is
/// about and declaring that it did.
///
/// The headers are the old app's, in its order, so both apps read what the
/// other wrote: `ReviewCount`, `SuccessCount`, `LastReviewed` (local ISO
/// time), `TimeToSolve` (seconds of the last attempt), `HintsUsed` and
/// `StarRating`. A header the game already has is changed where it stands;
/// a new one goes where the old app puts it, before the long ones.

/// The puzzle at [index] with one more attempt: solved or not, taking
/// [seconds], made at [now].
ChapterEdit recordAttempt(
  Chapter set, {
  required int index,
  required bool solved,
  required double seconds,
  required DateTime now,
}) {
  final stats = _statsAt(set, index);
  if (stats == null) return _gone;
  return _withTags(set, index, {
    'ReviewCount': '${stats.reviews + 1}',
    'SuccessCount': '${stats.successes + (solved ? 1 : 0)}',
    'LastReviewed': now.toIso8601String(),
    'TimeToSolve': '${(seconds * 1000).round() / 1000}',
  });
}

/// The puzzle at [index] rated [stars], 1 to 5; 0 takes the rating away.
ChapterEdit ratePuzzle(Chapter set, {required int index, required int stars}) {
  final stats = _statsAt(set, index);
  if (stats == null) return _gone;
  if (stats.stars == stars) return const ChapterUnchanged();
  return _withTags(set, index, {'StarRating': stars == 0 ? null : '$stars'});
}

const _gone = ChapterEditRefused('That puzzle is no longer in the set.');

PuzzleStats? _statsAt(Chapter set, int index) {
  if (index < 0 || index >= set.lines.length) return null;
  return puzzleOf(set.lines[index], index)?.stats;
}

/// Where the stats headers go and in what order, and the headers they go
/// before when the game has none of them yet.
const _statsOrder = [
  'ReviewCount',
  'SuccessCount',
  'LastReviewed',
  'TimeToSolve',
  'HintsUsed',
  'StarRating',
];
const _after = ['FlawTags', 'SolutionPv', 'SourceMovetext', 'CorrectLine'];

/// The game at [index] with [values] set, a null value taking the tag out.
ChapterEdit _withTags(Chapter set, int index, Map<String, String?> values) {
  final line = set.lines[index];
  final tree = line.tree;
  if (tree == null || !line.isWhole) {
    return const ChapterEditRefused(
      'That puzzle was not read whole, so it keeps the text it has.',
    );
  }
  var tags = line.tags;
  for (final MapEntry(:key, :value) in values.entries) {
    tags = _set(tags, key, value);
  }
  final retagged = ChapterLine(
    tags: tags,
    tree: tree,
    text: line.text,
    trailer: line.trailer,
    terminator: line.terminator,
    separator: line.separator,
  );
  final written = rewritten(retagged, tree);
  if (written case LineRefused(:final reason)) {
    return ChapterEditRefused('The puzzle could not be written: $reason.');
  }
  final lines = [...set.lines];
  lines[index] = (written as LineRewritten).line;
  return ChapterEdited(
    withLines(set, lines),
    GamesArranged.of(
      GamesWritten(rewritten: {index}),
      before: set.lines.length,
    ),
  );
}

List<PgnHeader> _set(List<PgnHeader> tags, String key, String? value) {
  final at = tags.indexWhere((tag) => tag is PgnTag && tag.key == key);
  if (value == null) {
    return at < 0 ? tags : [...tags]
      ..removeAt(at);
  }
  if (at >= 0) {
    final old = tags[at];
    return [...tags]..[at] = PgnTag(key, value, trailer: old.trailer);
  }
  return [...tags]..insert(_placeFor(tags, key), PgnTag(key, value));
}

/// Before the first header that comes after [key] in the old app's order,
/// or after the last header when none does.
int _placeFor(List<PgnHeader> tags, String key) {
  final later = {..._statsOrder.skip(_statsOrder.indexOf(key) + 1), ..._after};
  final at = tags.indexWhere((tag) => tag is PgnTag && later.contains(tag.key));
  return at < 0 ? tags.length : at;
}
