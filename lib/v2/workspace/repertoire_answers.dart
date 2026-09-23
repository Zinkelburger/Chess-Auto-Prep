import 'package:dartchess/dartchess.dart' show Side;

import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_sections.dart';
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/pgn_document_store.dart';
import 'gap_walk.dart';

/// What the other chapters of a repertoire answer: for each position at
/// which one of them has a move of ours, the name of that chapter.
///
/// A gap is a position the opponent reaches often and the repertoire has
/// no answer for — the repertoire, not the page. A reply the Petroff
/// chapter answers is not a gap in the Italian one, whatever the Italian
/// file says. The other chapters are read from disk and their positions
/// kept until [forget]: the library says when its files change, and the
/// chapter that was just open may have been edited, so a change of chapter
/// forgets too. Draft chapters do not count; a proposal is not an answer.
final class RepertoireAnswers {
  RepertoireAnswers({
    required ChapterFiles files,
    required PgnDocumentStore documents,
  }) : _files = files,
       _documents = documents;

  final ChapterFiles _files;
  final PgnDocumentStore _documents;

  /// What each chapter answers, by chapter, as last read.
  final _read = <ChapterRef, _Answered>{};

  /// Drops what was read; the next question reads the files again.
  void forget() => _read.clear();

  /// The positions the chapters of [chapter]'s repertoire other than itself
  /// answer from [side], each naming the first chapter, in folder order,
  /// that answers it.
  Future<Map<String, String>> around(ChapterRef chapter, Side side) async {
    final listing = await _files.list();
    if (listing is! Repertoires) return const {};
    final folder = listing.folders
        .where((f) => f.chapters.any((c) => c.path == chapter.path))
        .firstOrNull;
    if (folder == null) return const {};
    final answers = <String, String>{};
    // A course file holds many chapters; it is read once for all of them.
    final files = <String, Future<Chapter?>>{};
    for (final other in folder.chapters) {
      // By chapter, not by file: the other chapters of a course file are
      // other chapters.
      if (other == chapter || other.heading.draft) continue;
      final answered = _read[other] ??= _answeredIn(
        other,
        await (files[other.path] ??= _file(other)),
      );
      if (answered.side != side) continue;
      for (final position in answered.positions) {
        answers.putIfAbsent(position, () => other.name);
      }
    }
    return answers;
  }

  _Answered _answeredIn(ChapterRef ref, Chapter? file) {
    if (file == null) return _Answered.none;
    final chapter = sectionView(file, ref.section).chapter;
    return _Answered(
      chapter.side,
      answeredPositions(chapter.tree, chapter.side),
    );
  }

  Future<Chapter?> _file(ChapterRef ref) async {
    switch (await _documents.open(ref)) {
      case Opened(:final text):
        return readChapter(name: ref.fileName, text: text);
      case Absent():
        return null;
      case Unreadable(:final detail):
        log.w('read what ${ref.path} answers', detail);
        return null;
    }
  }
}

final class _Answered {
  const _Answered(this.side, this.positions);

  static const none = _Answered(null, <String>{});

  /// Null for a chapter that could not be read, which answers nothing.
  final Side? side;

  final Set<String> positions;
}
