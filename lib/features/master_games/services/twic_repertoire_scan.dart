/// Which TWIC games are worth looking at, given the books you actually play.
///
/// The TWIC corpus is two million games and almost none of them concern you.
/// The ones that do are the ones that walked into a line you have prepared —
/// either testing it, or leaving it somewhere your preparation stops.  That is
/// the same question the Games page asks about your own games, so it is the
/// same walker: [GameDeviationService] against the designated White and Black
/// repertoire folders.
///
/// A master game has no "me", so each game is tried against both books and
/// the deeper agreement wins.  Depth of agreement is the ranking, because a
/// game that followed your line for sixteen plies and then played something
/// you do not cover is exactly the game you want to see, while one that
/// transposed out on move three is noise.
library;

import '../../../services/master_games/master_games_db.dart';
import '../../games/services/game_deviation_service.dart';
import '../../games/services/game_moves.dart';
import '../../games/services/my_repertoire_settings.dart';

/// One game that reached one of your books.
class TwicMatch {
  const TwicMatch({
    required this.game,
    required this.report,
    required this.bookIsWhite,
  });

  final MasterGame game;
  final DeviationReport report;

  /// Which of your two books it followed.
  final bool bookIsWhite;

  /// Plies the game and your book agreed on.
  int get matchedPlies => report.matchedPlies;

  /// The game ran off the end of your preparation rather than diverging from
  /// a move you cover — an invitation to extend the line.
  bool get ranPastYourPrep => report.bookEnded;

  /// The game left your book at a move you *do* cover an alternative to: a
  /// direct test of the choice you made.
  bool get testedYourChoice => !report.inBook && !report.bookEnded;

  /// The whole game stayed inside your preparation.
  bool get stayedInBook => report.inBook;

  /// Strength of the encounter, for ranking equally deep games.
  int get topElo {
    final w = game.whiteElo ?? 0;
    final b = game.blackElo ?? 0;
    return w > b ? w : b;
  }
}

/// What a scan found.
class TwicScanResult {
  const TwicScanResult({
    required this.matches,
    required this.scanned,
    required this.hasWhiteBook,
    required this.hasBlackBook,
  });

  /// Deepest agreement first.
  final List<TwicMatch> matches;

  /// Games actually walked.
  final int scanned;

  final bool hasWhiteBook;
  final bool hasBlackBook;

  bool get hasAnyBook => hasWhiteBook || hasBlackBook;

  /// Games that went past the end of your preparation.
  int get pastPrepCount => matches.where((m) => m.ranPastYourPrep).length;

  /// Games that met a move you cover and chose differently.
  int get testedCount => matches.where((m) => m.testedYourChoice).length;

  /// One line for the browser header.
  String get headline {
    if (!hasAnyBook) {
      return 'No repertoire is designated as yours, so there is nothing to '
          'compare these games against.';
    }
    if (matches.isEmpty) {
      return 'None of these $scanned games reached your books.';
    }
    final games = scanned == 1 ? 'game' : 'games';
    return '${matches.length} of $scanned $games reached your books — '
        '$testedCount met a move you cover, $pastPrepCount ran past where '
        'your preparation stops.';
  }
}

/// Walks games against the designated books.
class TwicRepertoireScanner {
  TwicRepertoireScanner({
    GameDeviationService? deviations,
    MyRepertoireSettings? settings,
  }) : _deviations = deviations ?? GameDeviationService.instance,
       _settings = settings ?? MyRepertoireSettings.instance;

  final GameDeviationService _deviations;
  final MyRepertoireSettings _settings;

  /// Scan [games], keeping those that stayed with a book for at least
  /// [minPlies] half-moves.
  ///
  /// [onProgress] is called every [progressEvery] games; the walk yields to
  /// the event loop at the same points so a scan of several thousand games
  /// does not freeze the window.
  Future<TwicScanResult> scan({
    required List<MasterGame> games,
    int minPlies = 6,
    void Function(int done, int total)? onProgress,
    int progressEvery = 200,
    bool Function()? isCancelled,
  }) async {
    await _settings.ensureLoaded();
    final hasWhite = _settings.pathsFor(white: true).isNotEmpty;
    final hasBlack = _settings.pathsFor(white: false).isNotEmpty;

    final matches = <TwicMatch>[];
    var scanned = 0;

    if (!hasWhite && !hasBlack) {
      return const TwicScanResult(
        matches: [],
        scanned: 0,
        hasWhiteBook: false,
        hasBlackBook: false,
      );
    }

    for (final game in games) {
      if (isCancelled?.call() ?? false) break;
      scanned++;
      final sans = extractMainlineSans(game.movetext);
      if (sans.isEmpty) continue;

      TwicMatch? best;
      for (final white in [if (hasWhite) true, if (hasBlack) false]) {
        final report = await _deviations.analyzeGame(
          gameSans: sans,
          meWhite: white,
        );
        if (report == null || report.matchedPlies < minPlies) continue;
        if (best != null && report.matchedPlies <= best.matchedPlies) continue;
        best = TwicMatch(game: game, report: report, bookIsWhite: white);
      }
      if (best != null) matches.add(best);

      if (scanned % progressEvery == 0) {
        onProgress?.call(scanned, games.length);
        // Let the frame that shows the progress actually paint.
        await Future<void>.delayed(Duration.zero);
      }
    }
    onProgress?.call(scanned, games.length);

    matches.sort((a, b) {
      final depth = b.matchedPlies.compareTo(a.matchedPlies);
      if (depth != 0) return depth;
      return b.topElo.compareTo(a.topElo);
    });

    return TwicScanResult(
      matches: matches,
      scanned: scanned,
      hasWhiteBook: hasWhite,
      hasBlackBook: hasBlack,
    );
  }
}
