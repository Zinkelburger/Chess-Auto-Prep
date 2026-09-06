/// Aggregate "where did my openings go wrong" view over the recent-games
/// window: the per-game [DeviationReport]s collapse into one entry per
/// distinct deviation point, with the games that reached it.
///
/// Three kinds of entry, kept apart because they call for different action:
/// my mistakes (I had a book move and played something else — go re-learn
/// the line), gaps (the opponent played a move the book has no answer to —
/// go prepare one) and book ends (the prep ran out — go extend it).
library;

import 'dart:io';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart' show Chess, PgnGame;

import '../../../models/repertoire_line.dart';
import '../../../services/repertoire_service.dart';
import '../models/recent_game.dart';
import 'book_move_keys.dart';
import 'game_deviation_service.dart';
import 'game_moves.dart';
import '../../../utils/movetext_builder.dart';

/// One distinct deviation point, shared by every game in [games].
///
/// Mistake and gap entries group by (book position, move played): playing
/// two different wrong moves from the same book position is two things to
/// fix, and two opponent moves the book lacks are two lines to prepare.
/// Book-end entries group by the position alone: however the game
/// continued, the fix is the same — extend the prep past that point. The
/// position is the book's own move order to it, so two games that reached
/// it by different orders are one entry.
class OpeningReviewEntry {
  OpeningReviewEntry._(DeviationReport report)
    : chapterPath = report.chapterPath,
      chapterName = report.chapterName,
      lineName = report.lineName,
      pathSans = report.pathSans,
      playedSan = report.playedSan ?? '',
      expectedSans = report.expectedSans,
      matchedPlies = report.matchedPlies,
      byMe = report.byMe == true,
      mentionedAlternative = report.mentionedAlternative;

  final String chapterPath;
  final String chapterName;

  /// The book line the position sits in, by title (see
  /// [DeviationReport.lineName]); null for untitled hand-built lines.
  final String? lineName;

  /// The matched book prefix — what the builder navigates to on open.
  final List<String> pathSans;

  /// The first off-book move (of the first game that hit this entry, for
  /// book ends — mistake entries group by it, so there it is exact).
  final String playedSan;

  final List<String> expectedSans;
  final int matchedPlies;

  /// Whether the deviating move was mine.
  final bool byMe;

  /// Whether the book mentions the move I played as an alternative it does
  /// not recommend (see [DeviationReport.mentionedAlternative]).
  final bool mentionedAlternative;

  /// Games that reached this deviation point, in list (newest-first) order.
  final List<RecentGame> games = [];

  /// True for a book-end entry: the prep stops here rather than saying
  /// something else. The fix is to extend it, not to correct a move.
  bool get isBookEnd => expectedSans.isEmpty;

  /// True for a gap: the opponent played a move the book has no answer to.
  bool get isGap => !isBookEnd && !byMe;

  /// What to call the position: the book line's title when the chapter has
  /// them, else the chapter.
  String get placeName => lineName ?? chapterName;

  int get moveNumber => matchedPlies ~/ 2 + 1;

  /// The matched line as numbered movetext ("1. e4 c5 2. Nf3").
  String get lineDisplay => formatNumberedSans(pathSans);

  /// The deviating move with its number ("3... g6").
  String get playedDisplay => formatMoveAtPly(matchedPlies, playedSan);

  /// Book alternatives at the deviation point, numbered like [playedDisplay].
  String get expectedDisplay =>
      expectedSans.map((san) => formatMoveAtPly(matchedPlies, san)).join(' / ');
}

/// Everything the opening-review dialog shows.
class OpeningReviewData {
  const OpeningReviewData({
    required this.mistakes,
    required this.gaps,
    required this.bookEnds,
    required this.anyBookDesignated,
  });

  /// Positions where *I* had a book move and played something else,
  /// most-repeated first.
  final List<OpeningReviewEntry> mistakes;

  /// Positions where the *opponent* played a move the book has no answer
  /// to, most-repeated first. Not my mistake, but the thing a repertoire
  /// exists to close: the opponent move you keep meeting unprepared.
  final List<OpeningReviewEntry> gaps;

  /// Positions where the game ran past the end of the prep (either side's
  /// move — "who" is meaningless when the book has nothing to say).
  final List<OpeningReviewEntry> bookEnds;

  /// Whether any game in the window had a repertoire designated for my
  /// color — false means the empty state should point at Settings, not
  /// congratulate the user on staying in book.
  final bool anyBookDesignated;

  bool get isEmpty => mistakes.isEmpty && gaps.isEmpty && bookEnds.isEmpty;

  /// Distinct places the games left the books, all three kinds.
  int get issueCount => mistakes.length + gaps.length + bookEnds.length;

  /// The deviation points hit by more than one game, most-repeated first —
  /// the home column lists the top few inline, because a leak you keep
  /// walking into is the one worth fixing today. Empty when nothing repeats:
  /// the block then says nothing rather than promoting a one-off.
  List<OpeningReviewEntry> repeated({int limit = 3}) {
    final all = [
      for (final e in mistakes)
        if (e.games.length > 1) e,
      for (final e in gaps)
        if (e.games.length > 1) e,
      for (final e in bookEnds)
        if (e.games.length > 1) e,
    ];
    all.sort((a, b) {
      final byCount = b.games.length.compareTo(a.games.length);
      if (byCount != 0) return byCount;
      return a.matchedPlies.compareTo(b.matchedPlies);
    });
    return all.length > limit ? all.sublist(0, limit) : all;
  }
}

/// Collapse the games' per-game deviation reports into review entries.
///
/// Keys use [normalizeSan] so "Nf3" and "Nf3+" collapse together; the
/// position part of the key is the book's own move order, so transposed
/// games land on the same entry as direct ones.
OpeningReviewData aggregateOpeningReview(List<RecentGame> games) {
  final mistakes = <String, OpeningReviewEntry>{};
  final gaps = <String, OpeningReviewEntry>{};
  final bookEnds = <String, OpeningReviewEntry>{};
  var anyDesignated = false;

  for (final game in games) {
    anyDesignated = anyDesignated || game.bookDesignated;
    final report = game.deviation;
    if (report == null || report.inBook) continue;

    final lineKey = report.pathSans.map(normalizeSan).join('\u0000');
    final Map<String, OpeningReviewEntry> bucket;
    final String key;
    if (report.bookEnded) {
      bucket = bookEnds;
      key = lineKey;
    } else {
      bucket = report.byMe == true ? mistakes : gaps;
      key = '$lineKey\u0000${normalizeSan(report.playedSan!)}';
    }
    bucket.putIfAbsent(key, () => OpeningReviewEntry._(report)).games.add(game);
  }

  int byRepetitionThenDepth(OpeningReviewEntry a, OpeningReviewEntry b) {
    final byCount = b.games.length.compareTo(a.games.length);
    if (byCount != 0) return byCount;
    // Same count: earlier deviations first — a move-4 leak is cheaper to
    // fix and costs more games than a move-14 one.
    return a.matchedPlies.compareTo(b.matchedPlies);
  }

  return OpeningReviewData(
    mistakes: mistakes.values.toList()..sort(byRepetitionThenDepth),
    gaps: gaps.values.toList()..sort(byRepetitionThenDepth),
    bookEnds: bookEnds.values.toList()..sort(byRepetitionThenDepth),
    anyBookDesignated: anyDesignated,
  );
}

/// The chapter's lines that pass through the position [prefixSans] reaches
/// — the book side of the review detail view. Longest lines first (they
/// carry the most theory).
///
/// A line passes through when its mainline reaches that position after as
/// many plies, or when any of its variations does: the deviation walker
/// reads the whole tree, so a deviation it reports inside a bracketed line
/// must find that line here. Positions, not move orders, are compared,
/// matching the walker's transposition tolerance. Two kinds of line are not
/// "your book" and are skipped, again as the walker skips them: model games
/// (illustration) and lines that branch on our own side — the author's
/// alternatives in brackets, which after import are lines of their own
/// (see `RepertoireLine.firstBranchOnSide`). Lines from a custom start
/// position can't be matched from move one and are skipped too.
List<RepertoireLine> matchingBookLines(
  List<RepertoireLine> lines,
  List<String> prefixSans,
) {
  final prefix = positionKeysFromStart(prefixSans);
  // A prefix the game itself cannot replay matches nothing, rather than
  // matching every line on an empty key list.
  if (prefix.length < prefixSans.length) return const [];
  final target = prefix.isEmpty ? positionKey(Chess.initial) : prefix.last;
  final depth = prefix.length;
  bool matches(RepertoireLine line) {
    // Model games are illustration, not book — showing one as "your book"
    // next to the game you played would be answering with someone else's.
    if (line.isModelGame) return false;
    if (line.startPosition.fen != Chess.initial.fen) return false;
    if (line.firstBranchOnSide(white: line.color == 'white') != null) {
      return false;
    }
    if (line.moves.length >= depth) {
      final mainline = positionKeysFromStart(line.moves.take(depth).toList());
      if (mainline.length == depth && (depth == 0 || mainline.last == target)) {
        return true;
      }
    }
    if (line.fullPgn.isEmpty || !line.fullPgn.contains('(')) return false;
    try {
      return pgnTreeReachesPosition(
        PgnGame.parsePgn(line.fullPgn).moves,
        target,
        depth,
      );
    } catch (_) {
      return false;
    }
  }

  return lines.where(matches).toList()
    ..sort((a, b) => b.moves.length.compareTo(a.moves.length));
}

/// Read [OpeningReviewEntry.chapterPath] and return its lines through the
/// entry's matched prefix, with their comments (via the same
/// `parseRepertoirePgn` the deviation walker uses). Empty on any read or
/// parse failure — the detail view shows its "open in builder" fallback.
Future<List<RepertoireLine>> loadBookLinesForEntry(OpeningReviewEntry entry) =>
    loadBookLines(chapterPath: entry.chapterPath, prefixSans: entry.pathSans);

/// The book side of any deviation, aggregate or one-off: the chapter's lines
/// through [prefixSans], comments included.
Future<List<RepertoireLine>> loadBookLines({
  required String chapterPath,
  required List<String> prefixSans,
}) async {
  final String content;
  try {
    content = await File(chapterPath).readAsString();
  } catch (_) {
    return const [];
  }
  List<RepertoireLine> select() => matchingBookLines(
    RepertoireService().parseRepertoirePgn(content),
    prefixSans,
  );
  // A course export runs to tens of megabytes; parsing it here would freeze
  // the viewer for seconds. Small chapters stay on this isolate, where the
  // widget tests' fake clock can see them finish.
  return content.length > 512 * 1024 ? Isolate.run(select) : select();
}

/// SANs from the initial position as numbered movetext ("1. e4 c5 2. Nf3").
String formatNumberedSans(List<String> sans) => buildNumberedMovetext(sans);

/// The one-line verdict every game row and banner shows for a deviation:
/// what happened at the fork, with the move in it, so a reader knows where
/// they are without opening the game. Null for a game still in book.
///
/// Three shapes for three situations: "You left book: 6.f3 (book 6.Bg5)",
/// "Not in book: 7...O-O (book 7...Nc6 / 7...a6)" — the opponent's move
/// the book has no answer to — and "Book ends after 12...Rc8".
String? deviationVerdict(DeviationReport report) {
  final played = report.playedSan;
  if (played == null) return null;
  final ply = report.matchedPlies;
  if (report.bookEnded) {
    final last = report.pathSans.isEmpty
        ? null
        : formatMoveAtPly(ply - 1, report.pathSans.last);
    return last == null ? 'Book ends at the start' : 'Book ends after $last';
  }
  final book = report.expectedSans
      .map((san) => formatMoveAtPly(ply, san))
      .join(' / ');
  return report.byMe == true
      ? 'You left book: ${formatMoveAtPly(ply, played)} (book $book)'
      : 'Not in book: ${formatMoveAtPly(ply, played)} (book $book)';
}
