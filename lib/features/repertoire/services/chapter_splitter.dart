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

import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../../chess_core/pgn/pgn_text.dart' as pgn;
import '../../../chess_core/pgn/repertoire_document_mutation.dart';
import '../../../chess_core/pgn/repertoire_pgn_text.dart';
import '../../documents/models/pgn_document.dart';
import '../../documents/repositories/pgn_document_store.dart';
import '../../../services/repertoire_review_service.dart';
import '../../../services/repertoire_service.dart';
import '../../../services/storage/storage_service.dart';
import 'course_chapter_partition.dart';
import 'review_progress_repointer.dart';

class ChapterSplitResult {
  const ChapterSplitResult({
    required this.createdPaths,
    required this.movedLines,
    required this.remainingLines,
    required this.sourceRemoved,
  });
  final List<String> createdPaths;
  final int movedLines;
  final int remainingLines;
  final bool sourceRemoved;
}

enum ChapterSplitFailure {
  missing,
  noChapters,
  unsupported,
  destination,
  source,
  progress,
}

/// Mutation confirmed by this split; another writer may change the source.
enum ChapterSplitSourceState { unchanged, committed, uncertain }

/// Partial writes are retained, never rolled back or automatically retried.
/// [createdPaths] are acknowledged saves; [pathsToInspect] may be uncertain.
class ChapterSplitException implements Exception {
  ChapterSplitException(
    this.kind,
    this.message, {
    this.cause,
    List<String> createdPaths = const [],
    this.sourceState = ChapterSplitSourceState.unchanged,
    List<String> pathsToInspect = const [],
    this.sourceRemoved = false,
  }) : createdPaths = List.unmodifiable(createdPaths),
       pathsToInspect = List.unmodifiable(pathsToInspect);
  final ChapterSplitFailure kind;
  final String message;
  final Object? cause;
  final List<String> createdPaths;
  final ChapterSplitSourceState sourceState;
  final List<String> pathsToInspect;
  final bool sourceRemoved;
  @override
  String toString() => message;
}

class ChapterSplitter {
  ChapterSplitter({
    required this._documents,
    required StorageService storage,
    RepertoireReviewService? review,
    ReviewProgressRepointer? repointer,
  }) : _storage = storage,
       _repointer =
           repointer ??
           ReviewProgressRepointer(
             review: review ?? RepertoireReviewService(storage: storage),
           );

  final PgnDocumentStore _documents;
  final StorageService _storage;
  final ReviewProgressRepointer _repointer;

  Future<ChapterSplitResult> split(
    String chapterPath, {
    required bool isWhite,
  }) async {
    final opened = await _documents.open(chapterPath);
    if (opened is! PgnOpened) {
      throw ChapterSplitException(
        ChapterSplitFailure.missing,
        'That chapter could not be read. Reload the outline before splitting.',
        cause: opened,
      );
    }
    final baseline = opened.snapshot;
    final content = baseline.content;
    final (document, partition) = await Isolate.run(() {
      final document = splitRepertoireDocument(content);
      return (
        document,
        CourseChapterPartition(
          document.games,
          RepertoireService().parseRepertoirePgn(content),
        ),
      );
    });
    final titles = partition.chapters.keys.toList();
    if (titles.length < 2) {
      throw ChapterSplitException(
        ChapterSplitFailure.noChapters,
        'This chapter has no course chapters to split by.',
      );
    }
    final sourceRemoved = partition.remaining.isEmpty;
    if (sourceRemoved && !_documents.supportsQuarantine) {
      throw ChapterSplitException(
        ChapterSplitFailure.unsupported,
        'This host cannot safely remove the original chapter. No chapters were created.',
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
      final outcome = await _documents.create(
        path,
        reassemblePgnDocument(
          chapterHeader(
            name: name,
            isWhite: sideIsWhite,
            createdAt: DateTime.now(),
            courseChapter: title,
          ).trimRight(),
          partition.chapters[title]!,
        ),
      );
      if (outcome is! PgnSaved) {
        throw _writeFailure(outcome, path, createdPaths, isSource: false);
      }
      createdPaths.add(outcome.after.path);
      movedIdsByPath[outcome.after.path] = partition.ids[title] ?? {};
      movedLines += partition.chapters[title]!.length;
    }

    final recoveryPaths = <String>[];
    if (sourceRemoved) {
      final outcome = await _documents.quarantine(baseline);
      switch (outcome) {
        case PgnQuarantined(:final retained, :final recoveryPath):
          recoveryPaths.addAll([retained.path, recoveryPath]);
        case PgnQuarantineConflict():
          throw ChapterSplitException(
            ChapterSplitFailure.source,
            'The original chapter changed. Created chapters remain; training progress was not moved.',
            cause: outcome,
            createdPaths: createdPaths,
            pathsToInspect: [chapterPath],
          );
        case PgnQuarantineFailed():
          throw ChapterSplitException(
            ChapterSplitFailure.source,
            'The original chapter could not be removed. Created chapters remain; training progress was not moved.',
            cause: outcome,
            createdPaths: createdPaths,
            pathsToInspect: [chapterPath],
          );
        case PgnQuarantineUncertain(:final quarantinePath, :final recoveryPath):
          throw ChapterSplitException(
            ChapterSplitFailure.source,
            'The original chapter removal could not be confirmed. Inspect the retained files before another split. Training progress was not moved.',
            cause: outcome,
            createdPaths: createdPaths,
            sourceState: ChapterSplitSourceState.uncertain,
            pathsToInspect: [chapterPath, quarantinePath, recoveryPath],
          );
      }
    } else {
      final outcome = await _documents.save(
        baseline,
        reassemblePgnDocument(document.preamble, partition.remaining),
      );
      if (outcome is! PgnSaved) {
        throw _writeFailure(outcome, chapterPath, createdPaths, isSource: true);
      }
      if (outcome.recoveryPath case final path?) recoveryPaths.add(path);
    }

    try {
      await _repointer.repoint(
        from: chapterPath,
        movedIdsByPath: movedIdsByPath,
      );
    } catch (error) {
      throw ChapterSplitException(
        ChapterSplitFailure.progress,
        'The chapter files were split, but training progress could not be fully moved. The files were not rolled back. Do not repeat the split.',
        cause: error,
        createdPaths: createdPaths,
        sourceState: ChapterSplitSourceState.committed,
        sourceRemoved: sourceRemoved,
        pathsToInspect: recoveryPaths,
      );
    }
    return ChapterSplitResult(
      createdPaths: List.unmodifiable(createdPaths),
      movedLines: movedLines,
      remainingLines: partition.remaining.length,
      sourceRemoved: sourceRemoved,
    );
  }

  ChapterSplitException _writeFailure(
    PgnWriteResult outcome,
    String path,
    List<String> createdPaths, {
    required bool isSource,
  }) => ChapterSplitException(
    isSource ? ChapterSplitFailure.source : ChapterSplitFailure.destination,
    outcome is PgnWriteUncertain
        ? 'A chapter write could not be confirmed. Inspect the files before another split. Training progress was not moved.'
        : 'A chapter changed or could not be saved. Created chapters remain; training progress was not moved.',
    cause: outcome,
    createdPaths: createdPaths,
    sourceState: isSource && outcome is PgnWriteUncertain
        ? ChapterSplitSourceState.uncertain
        : ChapterSplitSourceState.unchanged,
    pathsToInspect: [
      path,
      if (outcome is PgnWriteUncertain && outcome.recoveryPath != null)
        outcome.recoveryPath!,
    ],
  );
}
