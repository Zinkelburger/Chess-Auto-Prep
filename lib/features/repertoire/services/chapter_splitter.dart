/// Turning one chapter file's `[White]` course chapters into real chapter
/// files.
///
/// A Chessable-style export is a single PGN whose games each name their
/// chapter in the `[White]` header. The trainer reads that (see
/// `RepertoireService.detectHeaderChapters`) and groups by it, but the
/// builder's structure *is* the folder — a chapter is a `.pgn` file — so an
/// imported course arrives as one 900-line "Main" and stays that way. This
/// promotes those header chapters to files, once, on request.
///
/// Two things make it more than a group-and-write:
///
///  1. **What a course export tells you depends on the whole file.** The id a
///     line gets, the name it shows, and whether it counts as a model game
///     are all read off the file it sits in — its position for the id, and
///     the `[White]` titles grouping the file for the other two. Cut the file
///     up and every one of those answers changes. So each game has the
///     answers it has *now* written into its own headers first (see
///     [_pinned]), which is what makes the split invisible to everything
///     downstream.
///  2. **Progress is keyed by file path.** Review schedules and per-move
///     progress carry `repertoireId` = the chapter's path, so they are
///     re-pointed at the new files in the same operation.
///
/// Destinations are written before the source is touched, so an interrupted
/// split can leave a duplicate but never a lost line.
library;

import 'package:path/path.dart' as p;

import '../../../models/repertoire_line.dart'
    show kModelGameResultTag, kModelGameWhiteTag;
import '../../../models/repertoire_move_progress.dart';
import '../../../models/repertoire_review_entry.dart';
import '../../../services/pgn_parsing_service.dart' as pgn;
import '../../../services/repertoire_line_ids.dart';
import '../../../services/repertoire_review_service.dart';
import '../../../services/repertoire_service.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../services/storage/storage_service.dart';
import 'chapter_store.dart';

/// What a split did, for the toast and for the caller to follow the active
/// chapter.
class ChapterSplitResult {
  /// New chapter files, in the order the course names them.
  final List<String> createdPaths;

  /// Lines that moved out of the source chapter.
  final int movedLines;

  /// Lines with no chapter of their own, left where they were.
  final int remainingLines;

  /// The source file held nothing but chapter-titled lines, so it is gone.
  final bool sourceRemoved;

  const ChapterSplitResult({
    required this.createdPaths,
    required this.movedLines,
    required this.remainingLines,
    required this.sourceRemoved,
  });
}

/// Raised when a split cannot be done, with a message the panel can toast.
class ChapterSplitException implements Exception {
  final String message;
  const ChapterSplitException(this.message);
  @override
  String toString() => message;
}

class ChapterSplitter {
  ChapterSplitter({
    StorageService? storage,
    RepertoireService? repertoire,
    RepertoireReviewService? review,
  }) : _storage = storage ?? StorageFactory.instance,
       _repertoire = repertoire ?? RepertoireService(),
       _review = review ?? RepertoireReviewService(storage: storage);

  final StorageService _storage;
  final RepertoireService _repertoire;
  final RepertoireReviewService _review;

  /// Splits [chapterPath] into one file per `[White]` chapter title, in the
  /// folder it already lives in.
  ///
  /// [isWhite] is the side stamped into a new chapter's `// Color:` header,
  /// used only when the source file does not declare one of its own.
  Future<ChapterSplitResult> split(
    String chapterPath, {
    required bool isWhite,
  }) async {
    final document = await _repertoire.readPgnDocument(chapterPath);
    if (document == null) {
      throw const ChapterSplitException('That chapter is no longer there.');
    }

    // The parser is the authority on both questions — which chapter a game
    // belongs to, and what id it resolves to — so ask it rather than
    // re-deriving either here.
    final parsed = await _repertoire.parseRepertoireFile(chapterPath);
    final titleByIndex = <int, String>{};
    final idByIndex = <int, String>{};
    final nameByIndex = <int, String>{};
    final modelGames = <int>{};
    for (final line in parsed) {
      if (line.gameIndex < 0 || line.gameIndex >= document.games.length) {
        continue;
      }
      idByIndex[line.gameIndex] = line.id;
      nameByIndex[line.gameIndex] = line.name;
      if (line.isModelGame) modelGames.add(line.gameIndex);
      final chapter = line.chapter;
      if (chapter != null && chapter.trim().isNotEmpty) {
        titleByIndex[line.gameIndex] = chapter.trim();
      }
    }

    // First-seen order, so the new files come out in the course's own order
    // rather than alphabetically.
    final titles = <String>[];
    for (var i = 0; i < document.games.length; i++) {
      final title = titleByIndex[i];
      if (title != null && !titles.contains(title)) titles.add(title);
    }
    if (titles.length < 2) {
      throw const ChapterSplitException(
        'This chapter has no course chapters to split by.',
      );
    }

    final folder = _storage.parentPath(chapterPath);
    final names = await _fileNamesFor(titles, folder: folder);

    // Pin id and name before anything moves — for the games that stay as
    // well as the ones that leave, since both are re-indexed by the split.
    final games = [
      for (var i = 0; i < document.games.length; i++)
        _pinned(
          document.games[i],
          id: idByIndex[i],
          name: nameByIndex[i],
          isModelGame: modelGames.contains(i),
        ),
    ];

    final color = pgn.extractRepertoireColor(document.preamble);
    final sideIsWhite = color == null ? isWhite : color == 'white';

    final createdPaths = <String>[];
    final movedIdsByPath = <String, Set<String>>{};
    var movedLines = 0;

    for (final title in titles) {
      final name = names[title]!;
      final path = _storage.chapterFilePath(folder, name);
      final indices = [
        for (var i = 0; i < games.length; i++)
          if (titleByIndex[i] == title) i,
      ];
      await _repertoire.writePgnDocument(
        path,
        preamble: ChapterStore.chapterHeader(
          name: name,
          isWhite: sideIsWhite,
          createdAt: DateTime.now(),
        ),
        games: [for (final i in indices) games[i]],
        createOnly: true,
      );
      createdPaths.add(path);
      movedIdsByPath[path] = {
        for (final i in indices)
          if (idByIndex[i] != null) idByIndex[i]!,
      };
      movedLines += indices.length;
    }

    // Only now is the source rewritten — every line above is already on disk
    // under its new chapter.
    final remaining = [
      for (var i = 0; i < games.length; i++)
        if (titleByIndex[i] == null) games[i],
    ];
    final sourceRemoved = remaining.isEmpty;
    if (sourceRemoved) {
      await _storage.deleteFile(chapterPath);
    } else {
      await _repertoire.writePgnDocument(
        chapterPath,
        preamble: document.preamble,
        games: remaining,
        expectedContent: document.originalContent,
      );
    }

    await _repointProgress(from: chapterPath, movedIdsByPath: movedIdsByPath);

    return ChapterSplitResult(
      createdPaths: createdPaths,
      movedLines: movedLines,
      remainingLines: remaining.length,
      sourceRemoved: sourceRemoved,
    );
  }

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
    return name.isEmpty ? 'Chapter' : name;
  }

  /// One distinct filename per title, avoiding both each other and the
  /// chapters already in [folder]. Two titles can collide once illegal
  /// characters are stripped, and a course chapter can share a name with a
  /// file that is already there.
  Future<Map<String, String>> _fileNamesFor(
    List<String> titles, {
    required String folder,
  }) async {
    final taken = <String>{
      for (final c in await _storage.listChapters(folder))
        p.basenameWithoutExtension(c.filePath).toLowerCase(),
    };
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

  static final _idHeader = RegExp(
    '^\\[(${RepertoireLineIds.headerKeys.join('|')})\\s+"',
    multiLine: true,
    caseSensitive: false,
  );

  static final _modelGameHeader = RegExp(
    '^\\[($kModelGameWhiteTag|$kModelGameResultTag)\\s+"',
    multiLine: true,
  );

  static final _eventHeader = RegExp(r'^\[Event .*\]$', multiLine: true);

  static String? _headerValue(String gameText, String key) => RegExp(
    '^\\[$key\\s+"([^"]*)"\\]\$',
    multiLine: true,
  ).firstMatch(gameText)?.group(1);

  /// [gameText] with [headers] added straight after its `[Event]` line, or at
  /// the top when it has none.
  static String _insertAfterEvent(String gameText, String headers) {
    final event = _eventHeader.firstMatch(gameText);
    return event == null
        ? '$headers\n$gameText'
        : gameText.replaceRange(event.end, event.end, '\n$headers');
  }

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
  static String _pinned(
    String gameText, {
    String? id,
    String? name,
    bool isModelGame = false,
  }) {
    var text = gameText;
    if (isModelGame && !_modelGameHeader.hasMatch(text)) {
      final white = _headerValue(text, 'White') ?? '?';
      final result = _headerValue(text, 'Result') ?? '*';
      text = _insertAfterEvent(
        text,
        '[$kModelGameWhiteTag "$white"]\n[$kModelGameResultTag "$result"]',
      );
    }
    if (name != null && name.trim().isNotEmpty) {
      final title = '[Event "${name.replaceAll('"', "'").trim()}"]';
      text = _eventHeader.hasMatch(text)
          ? text.replaceFirst(_eventHeader, title)
          : '$title\n$text';
    }
    if (id != null && !_idHeader.hasMatch(text)) {
      text = _insertAfterEvent(text, '[LineID "$id"]');
    }
    return text;
  }

  // ── Progress ───────────────────────────────────────────────────────────

  /// Re-points review schedules and per-move progress from [from] at the
  /// chapter each line landed in. Without this a split reads as 900 lines
  /// deleted and 900 new ones, and every due date is lost.
  Future<void> _repointProgress({
    required String from,
    required Map<String, Set<String>> movedIdsByPath,
  }) async {
    final newPathById = <String, String>{
      for (final entry in movedIdsByPath.entries)
        for (final id in entry.value) id: entry.key,
    };
    if (newPathById.isEmpty) return;

    final entries = await _review.loadAll();
    var changed = false;
    final rewritten = <RepertoireReviewEntry>[];
    for (final e in entries) {
      final to = e.repertoireId == from ? newPathById[e.lineId] : null;
      if (to == null) {
        rewritten.add(e);
        continue;
      }
      changed = true;
      rewritten.add(
        RepertoireReviewEntry(
          repertoireId: to,
          lineId: e.lineId,
          lineName: e.lineName,
          difficulty: e.difficulty,
          intervalDays: e.intervalDays,
          dueDateUtc: e.dueDateUtc,
          lastRating: e.lastRating,
          lastReviewedUtc: e.lastReviewedUtc,
          passCount: e.passCount,
          failCount: e.failCount,
        ),
      );
    }
    if (changed) await _review.saveAll(rewritten);

    final progress = await _review.loadMoveProgress();
    var progressChanged = false;
    final movedProgress = <RepertoireMoveProgress>[];
    for (final mp in progress) {
      final to = mp.repertoireId == from ? newPathById[mp.lineId] : null;
      if (to == null) {
        movedProgress.add(mp);
        continue;
      }
      progressChanged = true;
      movedProgress.add(
        RepertoireMoveProgress(
          repertoireId: to,
          lineId: mp.lineId,
          moveIndex: mp.moveIndex,
          correctStreak: mp.correctStreak,
          learned: mp.learned,
        ),
      );
    }
    if (progressChanged) await _review.saveMoveProgress(movedProgress);
  }
}
