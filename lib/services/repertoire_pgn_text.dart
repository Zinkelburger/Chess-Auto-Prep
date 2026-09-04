/// Editing a repertoire's PGN *as text*, without parsing it into a move tree.
///
/// Every function here takes game text and returns game text. That is the
/// point: a repertoire file carries far more than the standard headers — the
/// `LineID` that every later lookup depends on, the SM-2 review metadata, the
/// generator's `CumProb` — and a round trip through a PGN parser and
/// serializer drops whatever it does not model. Renaming a line, appending a
/// move, writing back a review: all of them rewrite the smallest span of text
/// that has to change and leave the rest byte-identical.
///
/// These lived as private methods on [RepertoireService], mixed in among file
/// I/O and move-tree parsing, so the fiddly parts — which headers survive a
/// merge, where a missing header gets inserted, whether a move needs its
/// number — could not be tested without a file on disk.
library;

import '../utils/movetext_builder.dart';

/// `[Event "..."]`, for replacing a line's title in place.
final RegExp _eventTagRe = RegExp(r'\[Event\s+"[^"]*"\]');

/// A whole line that is nothing but one header.
final RegExp _headerLineRe = RegExp(r'^\[(\w+)\s+"[^"]*"\]$');

/// A header at the start of a line, capturing key and value.
final RegExp _headerPairRe = RegExp(r'^\[(\w+)\s+"([^"]*)"\]');

/// Headers written first, in this order, when a game is rewritten.
///
/// The tail is the several spellings of a line id that files in the wild use;
/// all of them are preserved, and whichever one a file already had keeps its
/// position rather than being shuffled to the end.
const List<String> _standardHeaderOrder = [
  'Event',
  'Site',
  'Date',
  'Round',
  'White',
  'Black',
  'Result',
  'FEN',
  'SetUp',
  'ECO',
  'Opening',
  'LineID',
  'LineId',
  'Id',
  'Line',
  'Guid',
];

/// Join a document's preamble and games back into one PGN file.
///
/// One trailing newline, blank lines between games, no trailing whitespace —
/// so a rewrite that changed one game does not show up as a whole-file diff.
String reassemblePgnDocument(String preamble, List<String> games) {
  final sections = <String>[if (preamble.isNotEmpty) preamble, ...games];
  return '${sections.join('\n\n').trimRight()}\n';
}

/// [gameText] with its `Event` header set to [newTitle], adding the header
/// when the game has none.
String withEventTitle(String gameText, String newTitle) =>
    _eventTagRe.hasMatch(gameText)
    ? gameText.replaceFirst(_eventTagRe, '[Event "$newTitle"]')
    : '[Event "$newTitle"]\n$gameText';

/// Carry over any header [oldGame] had that [newGame] lacks.
///
/// The PGN editor serializes only the standard headers, so an edited game
/// comes back missing `LineID`, the review metadata and `CumProb`. Dropping
/// `LineID` orphans the line: every later lookup by id — rename, autosave,
/// delete — silently fails against a file that looks fine.
String mergeMissingHeaders(String oldGame, String newGame) {
  List<String> headerLines(String game) {
    final result = <String>[];
    for (final line in game.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        if (result.isNotEmpty) break;
        continue;
      }
      if (_headerLineRe.hasMatch(trimmed)) {
        result.add(trimmed);
      } else {
        break;
      }
    }
    return result;
  }

  String keyOf(String header) => _headerLineRe.firstMatch(header)!.group(1)!;

  final newKeys = headerLines(newGame).map(keyOf).toSet();
  final missing = headerLines(
    oldGame,
  ).where((h) => !newKeys.contains(keyOf(h))).toList();
  if (missing.isEmpty) return newGame;

  final lines = newGame.split('\n');
  var lastHeader = -1;
  for (int i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (_headerLineRe.hasMatch(trimmed)) {
      lastHeader = i;
    } else if (trimmed.isNotEmpty) {
      break;
    }
  }
  if (lastHeader == -1) {
    lines.insertAll(0, [...missing, '']);
  } else {
    lines.insertAll(lastHeader + 1, missing);
  }
  return lines.join('\n');
}

/// [gameText] with its SM-2 review headers replaced.
///
/// Other headers and the movetext survive; the standard headers are written
/// first so a file stays readable after a session has rewritten every game.
String gameWithReviewHeaders(
  String gameText, {
  required DateTime? lastReview,
  required double difficulty,
  required double intervalDays,
  required DateTime? dueDate,
  required int passCount,
  required int failCount,
}) {
  final headers = <String, String>{};
  final moveLines = <String>[];
  var pastHeaders = false;

  for (final line in gameText.split('\n')) {
    final trimmed = line.trim();
    if (!pastHeaders && _headerPairRe.hasMatch(trimmed)) {
      final match = _headerPairRe.firstMatch(trimmed)!;
      headers[match.group(1)!] = match.group(2)!;
    } else {
      pastHeaders = true;
      moveLines.add(line);
    }
  }

  String fmtDate(DateTime? d) => d == null ? '' : d.toUtc().toIso8601String();
  headers['LastReview'] = fmtDate(lastReview);
  headers['Difficulty'] = difficulty.toStringAsFixed(2);
  headers['Interval'] = intervalDays.toStringAsFixed(2);
  headers['DueDate'] = fmtDate(dueDate);
  headers['PassCount'] = passCount.toString();
  headers['FailCount'] = failCount.toString();

  final buffer = StringBuffer();
  final written = <String>{};
  for (final key in _standardHeaderOrder) {
    if (headers.containsKey(key)) {
      buffer.writeln('[$key "${headers[key]}"]');
      written.add(key);
    }
  }
  for (final entry in headers.entries) {
    if (!written.contains(entry.key)) {
      buffer.writeln('[${entry.key} "${entry.value}"]');
    }
  }
  buffer.writeln();
  buffer.write(moveLines.join('\n').trim());

  return buffer.toString().trimRight();
}

/// [san] as it should appear after [existingMoves]: numbered when it is
/// White's move, bare when it is Black's.
String formatNextSan(List<String> existingMoves, String san) {
  final nextIndex = existingMoves.length;
  return nextIndex.isEven ? '${(nextIndex ~/ 2) + 1}. $san' : san;
}

/// [gameText] with [san] appended to its movetext.
///
/// The movetext is re-flowed onto one line; the headers are untouched, which
/// is what keeps the line's id and review state intact.
String appendSanToGamePgn(
  String gameText,
  List<String> existingMoves,
  String san,
) {
  final headerLines = <String>[];
  final moveLines = <String>[];

  for (final line in gameText.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (_headerPairRe.hasMatch(trimmed)) {
      headerLines.add(line);
    } else {
      moveLines.add(trimmed);
    }
  }

  final moveText = moveLines.join(' ').trim();
  final suffix = formatNextSan(existingMoves, san);
  final updatedMoveText = moveText.isEmpty ? suffix : '$moveText $suffix';

  return [...headerLines, '', updatedMoveText].join('\n');
}

/// A new one-line game: just enough headers for the file to round-trip.
///
/// `White`/`Black` name the sides rather than players, because this is the
/// shape the repertoire trainer reads to know which side it is drilling.
String buildMinimalGamePgn(
  List<String> moves, {
  String? startingFen,
  required bool isWhiteRepertoire,
}) {
  final headers = <String>[
    '[Event "Repertoire Line"]',
    '[Date "${DateTime.now().toIso8601String().split('T')[0]}"]',
    '[White "${isWhiteRepertoire ? 'Me' : 'Opponent'}"]',
    '[Black "${isWhiteRepertoire ? 'Opponent' : 'Me'}"]',
    '[Result "1-0"]',
  ];

  if (startingFen != null && startingFen.trim().isNotEmpty) {
    headers.add('[FEN "$startingFen"]');
    headers.add('[SetUp "1"]');
  }

  return [...headers, '', buildNumberedMovetext(moves)].join('\n');
}
