import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_sections.dart';
import '../../chess/training/training_line.dart';
import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/pgn_document_store.dart';

/// One chapter's lines, under the chapter they come from, with the version
/// of its file they were worked out from: the saved one for the chapter on
/// the board, whose lines may include edits not written yet.
typedef ChapterLines = ({
  ChapterRef ref,
  List<TrainingLine> lines,
  Revision? revision,
});

/// Reads the other chapters of a repertoire, or of a book, for training
/// them together.
///
/// A proposed chapter is left out, being nobody's repertoire yet, and so is
/// one that cannot be read, which is logged: one bad file does not stop the
/// rest being trained.
final class ScopeReader {
  const ScopeReader({required this._files, required this._documents});

  final ChapterFiles _files;
  final PgnDocumentStore _documents;

  /// The chapters of the repertoire [open] is in, in the folder's order,
  /// with [open] itself taken as it is on the board rather than read again.
  Future<List<ChapterLines>> repertoireOf(ChapterLines open) async {
    final listing = await _files.list();
    final folder = listing is Repertoires
        ? listing.folders
              .where((f) => f.chapters.any((c) => c.path == open.ref.path))
              .firstOrNull
        : null;
    if (folder == null) return [open];
    return _read(folder.chapters, open);
  }

  /// Every chapter of every repertoire that [wanted] takes, in the folders'
  /// order, with [open] taken as it is on the board.
  Future<List<ChapterLines>> chaptersWhere(
    bool Function(ChapterRef ref) wanted,
    ChapterLines? open,
  ) async {
    final listing = await _files.list();
    if (listing is! Repertoires) return const [];
    return _read([
      for (final folder in listing.folders)
        for (final ref in folder.chapters)
          if (wanted(ref)) ref,
    ], open);
  }

  Future<List<ChapterLines>> _read(
    List<ChapterRef> refs,
    ChapterLines? open,
  ) async {
    // A file of several chapters is read once for all of them.
    final files = <String, Future<({Chapter chapter, Revision revision})?>>{};
    return [
      for (final ref in refs)
        if (ref == open?.ref)
          open!
        else if (!ref.heading.draft)
          if (await (files[ref.path] ??= _file(ref)) case final file?)
            (
              ref: ref,
              revision: file.revision,
              lines: trainingLines(
                sectionView(file.chapter, ref.section).chapter,
                source: ref.path,
              ),
            ),
    ];
  }

  Future<({Chapter chapter, Revision revision})?> _file(ChapterRef ref) async {
    switch (await _documents.open(ref)) {
      case Opened(:final text, :final revision):
        return (
          chapter: await readChapter(name: ref.fileName, text: text),
          revision: revision,
        );
      case Absent():
        return null;
      case Unreadable(:final detail):
        log.w('read ${ref.path} to train its repertoire', detail);
        return null;
    }
  }
}
