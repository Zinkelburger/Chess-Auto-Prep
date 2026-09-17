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
///     [CourseChapterPartition.pinGame]), which is what makes the split invisible to everything
///     downstream.
///  2. **Progress is keyed by file path.** Review schedules and per-move
///     progress carry `repertoireId` = the chapter's path, so they are
///     re-pointed at the new files in the same operation (see
///     [ReviewProgressRepointer], which a line move uses too).
///
/// Destinations are written before the source is touched, so an interrupted
/// split can leave a duplicate but never a lost line.
library;

import 'package:path/path.dart' as p;

import '../../../chess_core/pgn/pgn_text.dart' as pgn;
import '../../../services/repertoire_review_service.dart';
import '../../../services/repertoire_service.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../services/storage/storage_service.dart';
import 'chapter_store.dart';
import 'course_chapter_partition.dart';
import 'review_progress_repointer.dart';

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
    ReviewProgressRepointer? repointer,
  }) : _storage = storage ?? StorageFactory.instance,
       _repertoire = repertoire ?? RepertoireService(storage: storage),
       _repointer =
           repointer ??
           ReviewProgressRepointer(
             review: review ?? RepertoireReviewService(storage: storage),
           );

  final StorageService _storage;
  final RepertoireService _repertoire;
  final ReviewProgressRepointer _repointer;

  /// Splits [chapterPath] into one file per `[White]` chapter title, in the
  /// folder it already lives in.
  ///
  /// [isWhite] is the side stamped into a new chapter's `// Color:` header,
  /// used only when the source file does not declare one of its own.
  Future<ChapterSplitResult> split(
    String chapterPath, {
    required bool isWhite,
  }) async {
    final document = await _repertoire.files.readPgnDocument(chapterPath);
    if (document == null) {
      throw const ChapterSplitException('That chapter is no longer there.');
    }

    // The parser is the authority on both questions — which chapter a game
    // belongs to, and what id it resolves to — so ask it rather than
    // re-deriving either here.
    final parsed = await _repertoire.parseRepertoireFile(chapterPath);
    final partition = CourseChapterPartition(document.games, parsed);
    final titles = partition.chapters.keys.toList();
    if (titles.length < 2) {
      throw const ChapterSplitException(
        'This chapter has no course chapters to split by.',
      );
    }
    final folder = _storage.parentPath(chapterPath);
    final names = CourseChapterPartition.fileNamesFor(
      titles,
      (await _storage.listChapters(
        folder,
      )).map((c) => p.basenameWithoutExtension(c.filePath)),
    );

    final color = pgn.extractRepertoireColor(document.preamble);
    final sideIsWhite = color == null ? isWhite : color == 'white';

    final createdPaths = <String>[];
    final movedIdsByPath = <String, Set<String>>{};
    var movedLines = 0;

    for (final title in titles) {
      final name = names[title]!;
      final path = _storage.chapterFilePath(folder, name);
      await _repertoire.files.writePgnDocument(
        path,
        preamble: ChapterStore.chapterHeader(
          name: name,
          isWhite: sideIsWhite,
          createdAt: DateTime.now(),
          courseChapter: title,
        ),
        games: partition.chapters[title]!,
        createOnly: true,
      );
      createdPaths.add(path);
      movedIdsByPath[path] = partition.ids[title] ?? {};
      movedLines += partition.chapters[title]!.length;
    }

    // Only now is the source rewritten — every line above is already on disk
    // under its new chapter.
    final remaining = partition.remaining;
    final sourceRemoved = remaining.isEmpty;
    if (sourceRemoved) {
      await _storage.deleteFile(chapterPath);
    } else {
      await _repertoire.files.writePgnDocument(
        chapterPath,
        preamble: document.preamble,
        games: remaining,
        expectedContent: document.originalContent,
      );
    }

    await _repointer.repoint(from: chapterPath, movedIdsByPath: movedIdsByPath);

    return ChapterSplitResult(
      createdPaths: createdPaths,
      movedLines: movedLines,
      remainingLines: remaining.length,
      sourceRemoved: sourceRemoved,
    );
  }
}
