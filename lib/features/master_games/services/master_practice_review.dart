/// Your own games against master practice: where each one left it, who left
/// first, what masters play there instead, and the games worth opening.
///
/// The master database's `book` table already answers "what did masters play
/// from this position" in a sub-millisecond indexed lookup, for every
/// position in the first [kBookMaxPly] plies. Walking one of your games
/// through it is therefore cheap, and the walk is the whole feature: the
/// first move the book has never seen is where you (or your opponent) left
/// theory, the book rows at that position are the moves masters chose
/// instead, and each row remembers the strongest and most recent game that
/// played it — the games in *your* line, not a random page of the corpus.
///
/// Reports are aggregated per branch point (position + the move played
/// there), the way the opening review groups deviations from your own books,
/// so a mistake you keep repeating rises to the top instead of hiding among
/// twenty single games.
///
/// Pure apart from the two injected lookups; the walk is synchronous per
/// game and yields to the event loop between games so a window of a hundred
/// games does not freeze the dialog.
library;

import 'package:dartchess/dartchess.dart' show Chess, Move, Position;

import '../../../services/eval/eval_canonicalize.dart' show canonicalizeFen4;
import '../../../services/master_games/master_games_db.dart';
import '../../../utils/chess_utils.dart' show sanToUci, uciToSan;
import '../../../utils/movetext_builder.dart';
import '../../games/models/recent_game.dart';

/// Where one game parted from master practice.
class MasterPracticeReport {
  const MasterPracticeReport({
    required this.matchedPlies,
    required this.fen,
    required this.pathSans,
    required this.playedSan,
    required this.byMe,
    required this.alternatives,
    required this.lastBookMove,
  });

  /// Plies the game and the book agreed on — also the 0-based index of the
  /// first move the book had never seen.
  final int matchedPlies;

  /// The branch position: the one the first unseen move was played in, or the
  /// position the game (or the book) ended in.
  final String fen;

  /// The moves played to reach [fen].
  final List<String> pathSans;

  /// The first move outside master practice, or null when the game ended
  /// (or the book ran out) before any such move.
  final String? playedSan;

  /// Whether [playedSan] was mine. Null when nobody left — the book ended.
  final bool? byMe;

  /// What masters played from [fen], most played first. Empty when no master
  /// game continues from here.
  final List<BookMove> alternatives;

  /// The book row of the last move both sides agreed on, for "the games in
  /// this line" when there is nothing to compare the next move against.
  final BookMove? lastBookMove;

  /// Someone played a move masters never have.
  bool get isDeviation => playedSan != null && alternatives.isNotEmpty;

  /// The book has nothing from [fen]: either the corpus stops indexing here
  /// ([reachedBookDepth]) or no master game went on from this position.
  bool get bookEnded => alternatives.isEmpty;

  /// The book is only [kBookMaxPly] plies deep, and this game got there.
  bool get reachedBookDepth => matchedPlies >= kBookMaxPly;

  /// Master games that reached [fen] and went on from it.
  int get positionGames => alternatives.fold(0, (sum, m) => sum + m.games);

  /// Full-move number of the move at [matchedPlies].
  int get moveNumber => matchedPlies ~/ 2 + 1;

  bool get whiteToMove => matchedPlies.isEven;

  /// "9. Bd3" / "9... h6", or null when nothing was played.
  String? get playedDisplay {
    final san = playedSan;
    return san == null ? null : formatMoveAtPly(matchedPlies, san);
  }

  /// The last move inside master practice, numbered — "8... a6".
  String? get lastBookMoveDisplay => pathSans.isEmpty
      ? null
      : formatMoveAtPly(pathSans.length - 1, pathSans.last);

  /// Standard UCI of [playedSan] in [fen], for drawing it. Empty when it did
  /// not parse (which the walk prevents, but arrows must never throw).
  String get playedUci {
    final san = playedSan;
    if (san == null) return '';
    return sanToUci(fen, san) ?? '';
  }

  /// The SAN of one of [alternatives] in [fen].
  String alternativeSan(BookMove move) => uciToSan(fen, move.uci);

  /// Standard UCI of one of [alternatives], for drawing it.
  String alternativeUci(BookMove move) =>
      sanToUci(fen, alternativeSan(move)) ?? move.uci;

  /// The score, in [0, 1], for the side to move in [fen] with [move].
  double scoreForMover(BookMove move) =>
      whiteToMove ? move.whiteScore : 1 - move.whiteScore;

  /// Aggregation key: the position and the move played in it, so two games
  /// that reached the same branch by different move orders are one entry.
  ///
  /// When nobody left — the book ended — the position alone is the key, so
  /// every game that ran past the same point sits together whatever it
  /// played next.
  String get key => isDeviation
      ? '${canonicalizeFen4(fen)}|$playedSan'
      : canonicalizeFen4(fen);

  /// The mainline index the viewer lands on: just after a deviating move, so
  /// the move under discussion is the last one made, or on the branch
  /// position itself when the book simply ended there.
  int get viewerPly => isDeviation ? matchedPlies + 1 : matchedPlies;
}

/// One master game worth opening at a branch point.
class MasterKeyGame {
  const MasterKeyGame({
    required this.game,
    required this.moveSan,
    required this.reason,
  });

  final MasterGame game;

  /// The move it played from the branch position ("Be2").
  final String moveSan;

  /// Why it is here: "Strongest" or "Most recent".
  final String reason;

  /// The higher of the two ratings, for a one-glance strength.
  int get topElo {
    final w = game.whiteElo ?? 0;
    final b = game.blackElo ?? 0;
    return w > b ? w : b;
  }

  /// "Carlsen – Nakamura", surnames only.
  String get players => '${_surname(game.white)} – ${_surname(game.black)}';

  /// "Tata Steel 2026", or just the year when there is no event.
  String get where {
    final year = game.date.length >= 4 ? game.date.substring(0, 4) : '';
    final event = game.event.trim();
    if (event.isEmpty) return year;
    return year.isEmpty ? event : '$event $year';
  }

  static String _surname(String pgnName) {
    final comma = pgnName.indexOf(',');
    return comma <= 0 ? pgnName.trim() : pgnName.substring(0, comma).trim();
  }
}

/// One branch point, with every game of yours that reached it.
class MasterPracticeEntry {
  MasterPracticeEntry({required this.report, required this.keyGames});

  /// The report of the first game grouped here; every game in [games] agrees
  /// with it on position, move played and what masters play instead.
  final MasterPracticeReport report;

  /// Master games from the branch position, strongest first.
  final List<MasterKeyGame> keyGames;

  final List<RecentGame> games = [];

  /// The most recent of [games], for ordering equally common entries.
  DateTime? get latest {
    DateTime? best;
    for (final g in games) {
      final d = g.record.date;
      if (d != null && (best == null || d.isAfter(best))) best = d;
    }
    return best;
  }

  /// An opening name from any of the games' headers, when a platform sent
  /// one. Never guessed from the moves.
  String? get openingDisplay {
    for (final g in games) {
      final name = g.openingDisplay;
      if (name != null) return name;
    }
    return null;
  }

  /// The moves masters play here, most popular first, as SAN.
  List<String> alternativeSans({int limit = 3}) => [
    for (final m in report.alternatives.take(limit)) report.alternativeSan(m),
  ];
}

/// Everything the dialog shows.
class MasterPracticeReview {
  const MasterPracticeReview({
    required this.mine,
    required this.theirs,
    required this.inBook,
    required this.gamesChecked,
    required this.gamesSkipped,
  });

  /// Branch points where *I* played the first move masters never have.
  final List<MasterPracticeEntry> mine;

  /// Branch points where my opponent did.
  final List<MasterPracticeEntry> theirs;

  /// Games that stayed inside master practice until the book ran out.
  final List<MasterPracticeEntry> inBook;

  /// Games walked (those where my side is known and the moves parse).
  final int gamesChecked;

  /// Games left out because neither player was me, or they had no moves.
  final int gamesSkipped;

  bool get isEmpty => mine.isEmpty && theirs.isEmpty && inBook.isEmpty;

  int _count(List<MasterPracticeEntry> entries) =>
      entries.fold(0, (sum, e) => sum + e.games.length);

  int get myGames => _count(mine);
  int get theirGames => _count(theirs);
  int get inBookGames => _count(inBook);

  /// Average full-move number at which my games left master practice, over
  /// the games where someone did. Null when nobody left.
  double? get averageLeaveMove {
    var plies = 0;
    var n = 0;
    for (final e in [...mine, ...theirs]) {
      plies += e.report.matchedPlies * e.games.length;
      n += e.games.length;
    }
    return n == 0 ? null : plies / n / 2 + 1;
  }

  /// One sentence for the header: who left first, how often, and how deep.
  String headline(String windowLabel) {
    if (gamesChecked == 0) {
      return 'None of your $windowLabel could be checked.';
    }
    final parts = <String>[];
    if (myGames > 0) parts.add('you left master practice first in $myGames');
    if (theirGames > 0) {
      parts.add(
        myGames > 0
            ? 'your opponents in $theirGames'
            : 'your opponents left master practice first in $theirGames',
      );
    }
    if (inBookGames > 0) {
      parts.add(
        '$inBookGames stayed in theory as deep as the book goes '
        '(move ${kBookMaxPly ~/ 2})',
      );
    }
    final avg = averageLeaveMove;
    final depth = avg == null
        ? ''
        : ' Games leave theory around move ${avg.round()} on average.';
    final games = gamesChecked == 1 ? 'game' : 'games';
    return 'Of your $windowLabel ($gamesChecked $games checked), '
        '${parts.join(', ')}.$depth';
  }
}

/// Walks your games through the master book.
class MasterPracticeReviewer {
  MasterPracticeReviewer({required this.lookup, required this.gameById});

  /// Master moves from a position (the database's `book` table).
  final BookLookup lookup;

  /// A stored game by id, for the key games.
  final MasterGame? Function(int id) gameById;

  /// How many of the masters' moves get a key game each.
  static const int keyMoves = 4;

  /// Where [game] left master practice, or null when the game cannot be
  /// walked (my side unknown, no moves, or the first move does not parse).
  MasterPracticeReport? reportFor(RecentGame game) {
    final meWhite = game.meWhite;
    if (meWhite == null || game.sans.isEmpty) return null;

    Position pos = Chess.initial;
    final path = <String>[];
    BookMove? last;
    for (var ply = 0; ply < game.sans.length; ply++) {
      final san = game.sans[ply];
      final Move? parsed;
      try {
        parsed = pos.parseSan(san);
      } catch (_) {
        return _ended(pos, path, last);
      }
      if (parsed == null) {
        if (ply == 0) return null;
        return _ended(pos, path, last);
      }
      final fen = pos.fen;
      final moves = _movesFrom(fen);
      if (moves.isEmpty) {
        return MasterPracticeReport(
          matchedPlies: ply,
          fen: fen,
          pathSans: List.unmodifiable(path),
          playedSan: san,
          byMe: null,
          alternatives: const [],
          lastBookMove: last,
        );
      }
      BookMove? hit;
      for (final m in moves) {
        if (m.uci == parsed.uci) {
          hit = m;
          break;
        }
      }
      if (hit == null) {
        return MasterPracticeReport(
          matchedPlies: ply,
          fen: fen,
          pathSans: List.unmodifiable(path),
          playedSan: san,
          byMe: ply.isEven == meWhite,
          alternatives: moves,
          lastBookMove: last,
        );
      }
      last = hit;
      path.add(san);
      pos = pos.play(parsed);
    }
    return _ended(pos, path, last);
  }

  MasterPracticeReport _ended(
    Position pos,
    List<String> path,
    BookMove? last,
  ) => MasterPracticeReport(
    matchedPlies: path.length,
    fen: pos.fen,
    pathSans: List.unmodifiable(path),
    playedSan: null,
    byMe: null,
    alternatives: _movesFrom(pos.fen),
    lastBookMove: last,
  );

  List<BookMove> _movesFrom(String fen) {
    try {
      return lookup(fen);
    } catch (_) {
      return const [];
    }
  }

  /// Walk [games] and group them by branch point.
  ///
  /// Yields to the event loop every [yieldEvery] games; [isCancelled] stops
  /// the walk early with what it has.
  Future<MasterPracticeReview> review(
    List<RecentGame> games, {
    int yieldEvery = 10,
    bool Function()? isCancelled,
  }) async {
    final mine = <String, MasterPracticeEntry>{};
    final theirs = <String, MasterPracticeEntry>{};
    final inBook = <String, MasterPracticeEntry>{};
    var checked = 0;
    var skipped = 0;
    var walked = 0;

    for (final game in games) {
      if (isCancelled?.call() ?? false) break;
      final report = reportFor(game);
      if (report == null) {
        skipped++;
      } else {
        checked++;
        final bucket = switch (report.byMe) {
          true => mine,
          false => theirs,
          null => inBook,
        };
        (bucket[report.key] ??= MasterPracticeEntry(
          report: report,
          keyGames: _keyGames(report),
        )).games.add(game);
      }
      if (++walked % yieldEvery == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    List<MasterPracticeEntry> ordered(Map<String, MasterPracticeEntry> m) {
      final list = m.values.toList()
        ..sort((a, b) {
          final count = b.games.length.compareTo(a.games.length);
          if (count != 0) return count;
          final la = a.latest;
          final lb = b.latest;
          if (la != null && lb != null && la != lb) return lb.compareTo(la);
          return b.report.matchedPlies.compareTo(a.report.matchedPlies);
        });
      return list;
    }

    return MasterPracticeReview(
      mine: ordered(mine),
      theirs: ordered(theirs),
      inBook: ordered(inBook),
      gamesChecked: checked,
      gamesSkipped: skipped,
    );
  }

  /// The games to open at a branch point: for each of the masters' top moves
  /// its strongest game, plus the most recent game of the most popular move;
  /// when the book ends, the strongest and most recent games that played the
  /// last move both sides agreed on.
  List<MasterKeyGame> _keyGames(MasterPracticeReport report) {
    final out = <MasterKeyGame>[];
    final seen = <int>{};

    void add(int id, String san, String reason) {
      if (id == 0 || !seen.add(id)) return;
      final game = gameById(id);
      if (game == null) return;
      out.add(MasterKeyGame(game: game, moveSan: san, reason: reason));
    }

    if (report.alternatives.isNotEmpty) {
      final top = report.alternatives.take(keyMoves).toList();
      for (final m in top) {
        add(m.citeGameId, report.alternativeSan(m), 'Strongest');
      }
      add(top.first.recentGameId, report.alternativeSan(top.first), 'Latest');
    } else {
      final last = report.lastBookMove;
      if (last != null && report.pathSans.isNotEmpty) {
        final san = report.pathSans.last;
        add(last.citeGameId, san, 'Strongest');
        add(last.recentGameId, san, 'Latest');
      }
    }
    return out;
  }
}
