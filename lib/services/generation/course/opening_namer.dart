/// Naming move sequences from the bundled ECO opening book.
///
/// The book is FEN-keyed, so a line is named by the deepest book position it
/// passes through — transpositions get the right name for free, and a line
/// that leaves book keeps the last name it earned.
library;

import 'package:dartchess/dartchess.dart';

import '../../../utils/fen_utils.dart';
import '../../../utils/chess_utils.dart' show playSanOrNullMove;
import '../../opening_book_service.dart';

/// An ECO code and opening name, e.g. `B36` / `Sicilian Defense: Accelerated
/// Dragon, Maroczy Bind`.
class OpeningLabel {
  final String eco;
  final String name;

  const OpeningLabel({required this.eco, required this.name});

  /// The name split into its natural segments — publishers write
  /// `Family: Variation, Sub-variation`, and a course strips the parts its
  /// readers already know.
  List<String> get segments => [
    for (final part in name.split(RegExp(r':\s*|,\s*')))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

/// Resolves opening labels for move sequences played from one start position.
///
/// Construct once per export: replaying from the same root repeatedly is
/// cheap, and the alternative (threading positions through the planner) would
/// couple grouping to chess rules for no benefit.
class OpeningNamer {
  OpeningNamer({required OpeningBook book, required String startFen})
    : _book = book,
      _startFen = startFen;

  /// A namer that never resolves anything — used when the book failed to
  /// load, so naming degrades to move sequences instead of failing the run.
  factory OpeningNamer.unavailable({required String startFen}) =>
      OpeningNamer(book: OpeningBook(const {}), startFen: startFen);

  final OpeningBook _book;
  final String _startFen;

  final Map<String, OpeningLabel?> _cache = {};

  /// Deepest named opening reached along [movesSan], or null if the sequence
  /// never touches the book (or is not playable from the start position).
  OpeningLabel? label(List<String> movesSan) =>
      _cache.putIfAbsent(movesSan.join(' '), () => _resolve(movesSan));

  OpeningLabel? _resolve(List<String> movesSan) {
    Position position;
    try {
      position = Chess.fromSetup(Setup.parseFen(expandFen(_startFen)));
    } catch (_) {
      return null;
    }

    OpeningBookEntry? deepest;
    var deepestPly = -1;

    void consider(int ply) {
      final entry = _book.byFen[normalizeFen(position.fen)];
      if (entry == null) return;
      // Two book positions on one path: the later one is the more specific
      // name, which is what a reader wants.
      if (ply >= deepestPly) {
        deepest = entry;
        deepestPly = ply;
      }
    }

    consider(0);
    for (var ply = 0; ply < movesSan.length; ply++) {
      final next = playSanOrNullMove(position, movesSan[ply]);
      if (next == null) break;
      position = next;
      consider(ply + 1);
    }

    final entry = deepest;
    return entry == null
        ? null
        : OpeningLabel(eco: entry.eco, name: entry.name);
  }
}

// ── Move references ──────────────────────────────────────────────────────

/// Format the move at [ply] (0-based, relative to a position where
/// [rootWhiteToMove] holds and the move number is [startMoveNumber]) as a
/// standalone reference: `6.Be3` for White, `6...Bg7` for Black.
String formatMoveReference(
  String san,
  int ply, {
  required bool rootWhiteToMove,
  int startMoveNumber = 1,
}) {
  final absolutePly = ply + (rootWhiteToMove ? 0 : 1);
  final moveNumber = startMoveNumber + absolutePly ~/ 2;
  return absolutePly.isEven ? '$moveNumber.$san' : '$moveNumber...$san';
}

/// Format a run of moves starting at [fromPly] as readable movetext,
/// e.g. `7.Be2 O-O 8.O-O`.
String formatMoveRun(
  List<String> movesSan, {
  required int fromPly,
  required bool rootWhiteToMove,
  int startMoveNumber = 1,
  int limit = 3,
}) {
  final buffer = StringBuffer();
  final end = (fromPly + limit).clamp(0, movesSan.length);
  for (var ply = fromPly; ply < end; ply++) {
    final absolutePly = ply + (rootWhiteToMove ? 0 : 1);
    final moveNumber = startMoveNumber + absolutePly ~/ 2;
    if (buffer.isNotEmpty) buffer.write(' ');
    if (absolutePly.isEven) {
      buffer.write('$moveNumber.');
    } else if (ply == fromPly) {
      buffer.write('$moveNumber...');
    }
    buffer.write(movesSan[ply]);
  }
  return buffer.toString();
}
