import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_sections.dart';
import '../../chess/training/training_line.dart';
import '../../diagnostics/log.dart';
import '../../storage/book_snapshot.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/pgn_document_store.dart';
import '../../storage/training_snapshot.dart';

/// An open chapter may contribute unsaved lines, while its revision remains
/// the persisted source proof required by training writes.
typedef ChapterLines = ({
  ChapterRef ref,
  List<TrainingLine> lines,
  Revision? revision,
});

sealed class TrainingScopeRead {
  const TrainingScopeRead();
}

final class TrainingScopeFailed extends TrainingScopeRead {
  const TrainingScopeFailed(this.detail);
  final String detail;
}

/// Exactly the membership and PGN versions used to build this scope. The
/// final fence also checks the progress and book inputs before publication.
final class TrainingScopeReady extends TrainingScopeRead {
  TrainingScopeReady(List<ChapterLines> chapters, {this.membership})
    : chapters = List.unmodifiable([
        for (final chapter in chapters)
          (
            ref: chapter.ref,
            lines: List<TrainingLine>.unmodifiable(chapter.lines),
            revision: chapter.revision,
          ),
      ]),
      observed = Map.unmodifiable({
        for (final chapter in chapters)
          chapter.ref.path: chapter.revision ?? const Revision(''),
      });

  final List<ChapterLines> chapters;
  final Repertoires? membership;
  final Map<String, Revision> observed;
}

/// Reads a complete training scope. Missing or unreadable included chapters
/// refuse the scope; they never silently reduce the set the user requested.
final class ScopeReader {
  const ScopeReader({required this._files, required this._documents});

  final ChapterFiles _files;
  final PgnDocumentStore _documents;

  Future<TrainingScopeRead> repertoireOf(ChapterLines open) => _capture(
    open: open,
    select: (listing) {
      final folder = listing.folders
          .where((folder) => folder.chapters.any((ref) => ref == open.ref))
          .firstOrNull;
      if (folder == null) {
        throw const _ScopeProblem(
          'The open chapter is no longer in this repertoire. Reload it.',
        );
      }
      return folder.chapters;
    },
  );

  Future<TrainingScopeRead> chaptersWhere(
    bool Function(ChapterRef ref) wanted,
    ChapterLines? open,
  ) => _capture(
    open: open,
    select: (listing) => [
      for (final folder in listing.folders)
        for (final ref in folder.chapters)
          if (wanted(ref)) ref,
    ],
  );

  Future<TrainingScopeRead> _capture({
    required ChapterLines? open,
    required List<ChapterRef> Function(Repertoires) select,
  }) async {
    try {
      final listing = await _files.list();
      if (listing is RepertoiresUnreadable) {
        return TrainingScopeFailed(listing.detail);
      }
      final membership = listing as Repertoires;
      if (membership.unreadable.isNotEmpty) {
        return TrainingScopeFailed(membership.unreadable.first.detail);
      }
      final selected = List<ChapterRef>.unmodifiable(select(membership));
      final files = <String, ({Chapter chapter, Revision revision})>{};
      final chapters = <ChapterLines>[];
      for (final ref in selected) {
        if (ref.heading.draft) continue;
        if (ref == open?.ref) {
          chapters.add(open!);
          continue;
        }
        final file = files[ref.path] ??= await _read(ref);
        chapters.add((
          ref: ref,
          revision: file.revision,
          lines: trainingLines(
            sectionView(file.chapter, ref.section).chapter,
            source: ref.path,
          ),
        ));
      }
      final versions = <String, Revision>{};
      for (final chapter in chapters) {
        final revision = chapter.revision ?? const Revision('');
        final previous = versions[chapter.ref.path];
        if (previous != null && !sameChapterRevision(previous, revision)) {
          return const TrainingScopeFailed(
            'The course changed while its chapters were loading. Reload it.',
          );
        }
        versions[chapter.ref.path] = revision;
      }
      return TrainingScopeReady(chapters, membership: membership);
    } on _ScopeProblem catch (error) {
      return TrainingScopeFailed(error.detail);
    } on Object catch (error) {
      log.w('read a complete training scope', error);
      return TrainingScopeFailed(
        'The training chapters could not be read: $error',
      );
    }
  }

  Future<RepertoireValidation> validate(
    TrainingScopeReady scope, {
    BookSource? book,
    TrainingReadSet? training,
  }) => _files.validate(
    scope.membership,
    observed: scope.observed,
    book: book,
    training: training,
  );

  Future<({Chapter chapter, Revision revision})> _read(ChapterRef ref) async {
    switch (await _documents.open(ref)) {
      case Opened(:final text, :final revision):
        return (
          chapter: await readChapter(name: ref.fileName, text: text),
          revision: revision,
        );
      case Absent():
        throw _ScopeProblem(
          '${ref.name} is missing. Reload the repertoire before training.',
        );
      case Unreadable(:final detail):
        log.w('read ${ref.path} to train its repertoire', detail);
        throw _ScopeProblem('${ref.name} could not be read: $detail');
    }
  }
}

final class _ScopeProblem implements Exception {
  const _ScopeProblem(this.detail);
  final String detail;
}
