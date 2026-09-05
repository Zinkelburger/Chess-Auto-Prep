/// Aggregate "where did my openings go wrong" view over the recent-games
/// window: the per-game [DeviationReport]s collapse into one entry per
/// distinct deviation point, with the games that reached it.
///
/// Two kinds of entry, kept apart because they call for different action:
/// real mistakes (I had a book move and played something else — go re-learn
/// the line) and book ends (the prep ran out — go extend it).
library;

import 'dart:io';

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
/// Mistake entries group by (matched line, move I played): playing two
/// different wrong moves from the same book position is two things to fix.
/// Book-end entries group by the matched line alone: however the game
/// continued, the fix is the same — extend the prep past that point.
class OpeningReviewEntry {
  OpeningReviewEntry._(DeviationReport report)
    : chapterPath = report.chapterPath,
      chapterName = report.chapterName,
      pathSans = report.pathSans,
      playedSan = report.playedSan ?? '',
      expectedSans = report.expectedSans,
      matchedPlies = report.matchedPlies;

  final String chapterPath;
  final String chapterName;

  /// The matched book prefix — what the builder navigates to on open.
  final List<String> pathSans;

  /// The first off-book move (of the first game that hit this entry, for
  /// book ends — mistake entries group by it, so there it is exact).
  final String playedSan;

  final List<String> expectedSans;
  final int matchedPlies;

  /// Games that reached this deviation point, in list (newest-first) order.
  final List<RecentGame> games = [];

  /// True for a book-end entry: the prep stops here rather than saying
  /// something else. The fix is to extend it, not to correct a move.
  bool get isBookEnd => expectedSans.isEmpty;

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
    required this.bookEnds,
    required this.anyBookDesignated,
  });

  /// Positions where *I* had a book move and played something else,
  /// most-repeated first.
  final List<OpeningReviewEntry> mistakes;

  /// Positions where the game ran past the end of the prep (either side's
  /// move — "who" is meaningless when the book has nothing to say).
  final List<OpeningReviewEntry> bookEnds;

  /// Whether any game in the window had a repertoire designated for my
  /// color — false means the empty state should point at Settings, not
  /// congratulate the user on staying in book.
  final bool anyBookDesignated;

  bool get isEmpty => mistakes.isEmpty && bookEnds.isEmpty;

  /// The deviation points hit by more than one game, most-repeated first —
  /// the home column lists the top few inline, because a leak you keep
  /// walking into is the one worth fixing today. Empty when nothing repeats:
  /// the block then says nothing rather than promoting a one-off.
  List<OpeningReviewEntry> repeated({int limit = 3}) {
    final all = [
      for (final e in mistakes)
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
/// Opponent deviations are skipped entirely: the opponent leaving book is
/// not an opening mistake of mine to review (the per-game chip still shows
/// it). Keys use [normalizeSan] so "Nf3" and "Nf3+" reached through
/// different move orders of the same line collapse together.
OpeningReviewData aggregateOpeningReview(List<RecentGame> games) {
  final mistakes = <String, OpeningReviewEntry>{};
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
    } else if (report.byMe == true) {
      bucket = mistakes;
      key = '$lineKey\u0000${normalizeSan(report.playedSan!)}';
    } else {
      continue;
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
    bookEnds: bookEnds.values.toList()..sort(byRepetitionThenDepth),
    anyBookDesignated: anyDesignated,
  );
}

/// The chapter's lines that pass through [prefixSans] — the book side of the
/// review detail view. Longest lines first (they carry the most theory).
///
/// A line passes through the prefix when its mainline does, or when any of
/// its variations does: the deviation walker reads the whole tree, so a
/// deviation it reports inside a bracketed line must find that line here.
/// Moves are compared as moves (see `book_move_keys.dart`), matching the
/// walker's tolerance for spelling differences. Lines from a custom start
/// position can't be prefix-matched and are skipped (same rule as the
/// walker's trie build).
List<RepertoireLine> matchingBookLines(
  List<RepertoireLine> lines,
  List<String> prefixSans,
) {
  final prefix = moveKeysFromStart(prefixSans);
  // A prefix the game itself cannot replay matches nothing, rather than
  // matching every line on an empty key list.
  if (prefix.length < prefixSans.length) return const [];
  bool matches(RepertoireLine line) {
    // Model games are illustration, not book — showing one as "your book"
    // next to the game you played would be answering with someone else's.
    if (line.isModelGame) return false;
    if (line.startPosition.fen != Chess.initial.fen) return false;
    if (line.moves.length >= prefix.length) {
      final mainline = moveKeysFromStart(
        line.moves.take(prefix.length).toList(),
      );
      if (mainline.length == prefix.length) {
        var same = true;
        for (var i = 0; i < prefix.length; i++) {
          if (mainline[i] != prefix[i]) {
            same = false;
            break;
          }
        }
        if (same) return true;
      }
    }
    if (line.fullPgn.isEmpty) return false;
    try {
      return pgnTreeReaches(PgnGame.parsePgn(line.fullPgn).moves, prefix);
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
  final lines = RepertoireService().parseRepertoirePgn(content);
  return matchingBookLines(lines, prefixSans);
}

/// SANs from the initial position as numbered movetext ("1. e4 c5 2. Nf3").
String formatNumberedSans(List<String> sans) => buildNumberedMovetext(sans);
