/// Lightweight game row for navigation UI (nav bar + search dialog).
library;

import '../models/pgn_game_entry.dart';
import '../models/repertoire_line.dart' show isModelGameHeaders;
import '../services/repertoire_service.dart';

class GameNavItem {
  static final _chapterCache = Expando<_ChapterDetection>();

  final String label;
  final int studyRating;
  final String studySummary;
  final Map<String, String> headers;

  /// Chapter detected against the complete file, before filtering or sorting.
  final String? chapter;

  const GameNavItem({
    required this.label,
    required this.studyRating,
    this.studySummary = '',
    this.headers = const {},
    this.chapter,
  });

  factory GameNavItem.fromEntry(PgnGameEntry game, {String? chapter}) =>
      GameNavItem(
        label: game.label,
        studyRating: game.studyRating,
        studySummary: game.studySummary,
        headers: game.headers,
        chapter: chapter,
      );

  /// Detect chapters with the same header semantics used by repertoire
  /// training. [allGames] must be in file order: chapter detection compares
  /// contiguous runs of White, Black and Event titles.
  ///
  /// [visibleGames] may filter/reorder the original entry objects. Returned
  /// indices match that list, while chapter membership remains a whole-file
  /// property even when only one game survives a filter.
  static List<GameNavItem> fromEntries(
    List<PgnGameEntry> allGames, {
    List<PgnGameEntry>? visibleGames,
  }) {
    var detection = _chapterCache[allGames];
    if (detection == null || !detection.matches(allGames)) {
      detection = _ChapterDetection(allGames);
      _chapterCache[allGames] = detection;
    }
    return [
      for (final game in visibleGames ?? allGames)
        GameNavItem.fromEntry(game, chapter: detection.chapters[game]),
    ];
  }
}

typedef _ChapterInput = ({
  PgnGameEntry game,
  String? white,
  String? black,
  String? event,
  String? result,
  bool modelGame,
});

/// Weakly keyed by the source list so closing a file releases its cache.
/// Validate the detector's inputs without allocating on normal rebuilds;
/// entry/header identity alone would miss metadata edits made in place.
class _ChapterDetection {
  final _inputs = <_ChapterInput>[];
  final chapters = Map<PgnGameEntry, String?>.identity();

  _ChapterDetection(List<PgnGameEntry> games) {
    final service = RepertoireService();
    final headers = [for (final game in games) game.headers];
    final key = service.chapterHeaderKey(headers);
    final titles = key == null
        ? null
        : service.detectHeaderChapters(headers, key: key);
    for (var i = 0; i < games.length; i++) {
      final game = games[i];
      final tags = game.headers;
      chapters[game] = titles?[i];
      _inputs.add((
        game: game,
        white: tags['White'],
        black: tags['Black'],
        event: tags['Event'],
        result: tags['Result'],
        modelGame: isModelGameHeaders(tags),
      ));
    }
  }

  bool matches(List<PgnGameEntry> games) {
    if (_inputs.length != games.length) return false;
    for (var i = 0; i < games.length; i++) {
      final input = _inputs[i];
      final game = games[i];
      final tags = game.headers;
      if (!identical(input.game, game) ||
          input.white != tags['White'] ||
          input.black != tags['Black'] ||
          input.event != tags['Event'] ||
          input.result != tags['Result'] ||
          input.modelGame != isModelGameHeaders(tags)) {
        return false;
      }
    }
    return true;
  }
}
