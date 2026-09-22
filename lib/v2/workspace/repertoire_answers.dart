import 'package:dartchess/dartchess.dart' show Side;

import '../chess/pgn/chapter.dart';
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

  /// What each chapter file answers, by path, as last read.
  final _read = <String, _Answered>{};

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
    for (final other in folder.chapters) {
      if (other.path == chapter.path || other.heading.draft) continue;
      final answered = _read[other.path] ??= await _answeredIn(other);
      if (answered.side != side) continue;
      for (final position in answered.positions) {
        answers.putIfAbsent(position, () => other.name);
      }
    }
    return answers;
  }

  Future<_Answered> _answeredIn(ChapterRef ref) async {
    switch (await _documents.open(ref)) {
      case Opened(:final text):
        final chapter = await readChapter(name: ref.name, text: text);
        return _Answered(
          chapter.side,
          answeredPositions(chapter.tree, chapter.side),
        );
      case Absent():
        return _Answered.none;
      case Unreadable(:final detail):
        log.w('read what ${ref.path} answers', detail);
        return _Answered.none;
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
