/// Pure course partitioning shared by existing chapter splitting and staged import.
library;

import '../../../models/repertoire_line.dart';
import '../../../utils/safe_file_name.dart';
import 'pgn_game_headers.dart';
import 'review_progress_repointer.dart';

class CourseChapterPartition {
  CourseChapterPartition(List<String> source, List<RepertoireLine> parsed) {
    final byIndex = {for (final line in parsed) line.gameIndex: line};
    for (var i = 0; i < source.length; i++) {
      final line = byIndex[i];
      final title = line?.chapter?.trim();
      final game = pinGame(
        source[i],
        id: line?.id,
        name: line?.name,
        isModelGame: line?.isModelGame ?? false,
      );
      if (title == null || title.isEmpty) {
        remaining.add(game);
      } else {
        (chapters[title] ??= []).add(game);
        if (line != null) (ids[title] ??= {}).add(line.id);
      }
    }
  }
  final Map<String, List<String>> chapters = {};
  final Map<String, Set<String>> ids = {};
  final List<String> remaining = [];

  // ── Names ──────────────────────────────────────────────────────────────

  /// Characters no filesystem this app targets will take, plus control
  /// characters. Same set [RepertoireOutlineService.validateName] refuses,
  /// except here they are replaced rather than rejected: the user did not
  /// type these names, the course did.
  static final _illegal = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

  /// A chapter title as a filename: illegal characters become spaces, runs of
  /// whitespace collapse, and the result is capped well short of any
  /// filesystem's limit ("QGD: Other Lines" → "QGD Other Lines").
  static String fileNameFor(String title) {
    var name = title.replaceAll(_illegal, ' ');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.length > 80) name = name.substring(0, 80).trim();
    // Windows takes neither a trailing dot nor a bare dot name.
    while (name.endsWith('.')) {
      name = name.substring(0, name.length - 1).trimRight();
    }
    if (name.isEmpty) return 'Chapter';
    return validateSafeFileName(name) == null ? name : 'Chapter $name';
  }

  /// One distinct filename per title, avoiding both each other and the
  /// chapters already in the destination folder. Two titles can collide once illegal
  /// characters are stripped, and a course chapter can share a name with a
  /// file that is already there.
  static Map<String, String> fileNamesFor(
    List<String> titles,
    Iterable<String> existing,
  ) {
    final taken = existing.map((name) => name.toLowerCase()).toSet();
    final names = <String, String>{};
    for (final title in titles) {
      final base = fileNameFor(title);
      var candidate = base;
      var n = 2;
      while (!taken.add(candidate.toLowerCase())) {
        candidate = '$base ($n)';
        n++;
      }
      names[title] = candidate;
    }
    return names;
  }

  // ── Pinning ────────────────────────────────────────────────────────────

  static final _modelGameHeader = RegExp(
    '^\\[($kModelGameWhiteTag|$kModelGameResultTag)\\s+"',
    multiLine: true,
  );

  /// [gameText] with the three things the split would otherwise take from it
  /// written into its own headers.
  ///
  ///  * `[LineID]`, when it has no id header of its own: the fallback id
  ///    encodes the game's position in the file, so a move renames the line
  ///    and orphans its training progress.
  ///  * `[Event]`, set to the name the line shows now: a course export names
  ///    the *variation* in `[Black]`, and the parser only reads that header
  ///    for a file whose `[White]` titles group it. Once a chapter is one
  ///    file, they no longer do, and every line in it would fall back to the
  ///    course's `[Event]` — the same name for all of them.
  ///
  ///  * The model-game tags, for a game the parser calls a model game. That
  ///    verdict also comes from the `[White]` titles grouping the file — a
  ///    real game among chapter-titled lines — so the last model games left
  ///    behind in the source would come back as lines to drill.
  ///
  /// A game that did not parse has none of these, and is passed through
  /// untouched.
  static String pinGame(
    String gameText, {
    String? id,
    String? name,
    bool isModelGame = false,
  }) {
    var text = gameText;
    if (isModelGame && !_modelGameHeader.hasMatch(text)) {
      final white = pgnHeaderValue(text, 'White') ?? '?';
      final result = pgnHeaderValue(text, 'Result') ?? '*';
      text = insertHeadersAfterEvent(
        text,
        '[$kModelGameWhiteTag "$white"]\n[$kModelGameResultTag "$result"]',
      );
    }
    if (name != null && name.trim().isNotEmpty) {
      final title = '[Event "${name.replaceAll('"', "'").trim()}"]';
      text = eventHeaderPattern.hasMatch(text)
          ? text.replaceFirst(eventHeaderPattern, title)
          : '$title\n$text';
    }
    if (id != null) text = ReviewProgressRepointer.pinLineId(text, id);
    return text;
  }
}
