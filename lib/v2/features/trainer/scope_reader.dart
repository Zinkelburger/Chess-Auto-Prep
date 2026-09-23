import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_sections.dart';
import '../../chess/training/training_line.dart';
import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/pgn_document_store.dart';

/// One chapter's lines, under the chapter they come from.
typedef ChapterLines = ({ChapterRef ref, List<TrainingLine> lines});

/// Reads the other chapters of a repertoire, for training it whole.
final class ScopeReader {
  const ScopeReader({
    required ChapterFiles files,
    required PgnDocumentStore documents,
  }) : _files = files,
       _documents = documents;

  final ChapterFiles _files;
  final PgnDocumentStore _documents;

  /// The chapters of the repertoire [open] is in, in the folder's order,
  /// with [open] itself taken from [openLines] rather than read again: the
  /// board has it, edits and all. A proposed chapter is left out, being
  /// nobody's repertoire yet, and so is one that cannot be read, which is
  /// logged: one bad file does not stop the rest being trained.
  Future<List<ChapterLines>> repertoireOf(
    ChapterRef open,
    List<TrainingLine> openLines,
  ) async {
    final listing = await _files.list();
    final folder = listing is Repertoires
        ? listing.folders
              .where((f) => f.chapters.any((c) => c.path == open.path))
              .firstOrNull
        : null;
    if (folder == null) return [(ref: open, lines: openLines)];
    // A file of several chapters is read once for all of them.
    final files = <String, Future<Chapter?>>{};
    return [
      for (final ref in folder.chapters)
        if (ref == open)
          (ref: open, lines: openLines)
        else if (!ref.heading.draft)
          if (await (files[ref.path] ??= _read(ref)) case final file?)
            (
              ref: ref,
              lines: trainingLines(
                sectionView(file, ref.section, name: ref.name).chapter,
                source: ref.path,
              ),
            ),
    ];
  }

  Future<Chapter?> _read(ChapterRef ref) async {
    switch (await _documents.open(ref)) {
      case Opened(:final text):
        return readChapter(name: ref.name, text: text);
      case Absent():
        return null;
      case Unreadable(:final detail):
        log.w('read ${ref.path} to train its repertoire', detail);
        return null;
    }
  }
}
