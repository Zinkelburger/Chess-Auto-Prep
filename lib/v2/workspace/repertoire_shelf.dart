import 'dart:isolate';

import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_sections.dart';
import '../chess/repertoire_index.dart';
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/document_ref.dart';
import '../storage/pgn_document_store.dart';

/// The user's repertoire chapters on disk, each read and indexed once and
/// again only when its file changes: what the explorer's Book and the book check
/// look positions up in.
///
/// Every repertoire is here, White's and Black's; a reader takes the ones
/// of the side it wants. Draft chapters are left out, since a proposal is
/// not a line the user plays. A course file holds many chapters by tag
/// ([ChapterRef.section]): it is read once, and each of its chapters is
/// indexed from that chapter's own games, so a line counts once, in the
/// chapter it belongs to.
final class RepertoireShelf {
  RepertoireShelf({
    required ChapterFiles files,
    required PgnDocumentStore documents,
  }) : _files = files,
       _documents = documents;

  final ChapterFiles _files;
  final PgnDocumentStore _documents;

  /// What each chapter plays, as the last whole read left it. A read builds
  /// its own and puts it here when it ends, so [refs] and [indexOf] always
  /// come from the same read.
  var _indexed = <ChapterRef, RepertoireIndex>{};

  /// The version of each file its chapters were indexed from: a file whose
  /// bytes are the same is not parsed again.
  var _revisions = <String, Revision>{};

  List<ChapterRef> _refs = const [];
  bool _stale = true;
  Future<void>? _reading;

  /// The repertoire chapters in folder order, drafts left out, as last
  /// listed.
  List<ChapterRef> get refs => _refs;

  /// Whether the files must be read again before they are believed: they
  /// changed, or a read of them has not finished.
  bool get stale => _stale || _reading != null;

  /// [ref]'s index as last read; null when it could not be read.
  RepertoireIndex? indexOf(ChapterRef ref) => _indexed[ref];

  /// The files changed on disk: they are read again the next time someone
  /// reads, and only the ones whose bytes changed are parsed again.
  void forget() => _stale = true;

  /// Reads until nothing is stale, so a change that lands while the files
  /// are being read is read too. [gone] stops it early.
  Future<void> read({required bool Function() gone}) async {
    while (!gone()) {
      final reading = _reading;
      if (reading != null) {
        await reading;
      } else if (_stale) {
        await (_reading = _readOnce(gone).whenComplete(() => _reading = null));
      } else {
        return;
      }
    }
  }

  /// One read, for the caller whose [gone] it is. Another reader may be
  /// waiting on it, so a read that caller gives up leaves the files stale
  /// for the next one rather than believed.
  Future<void> _readOnce(bool Function() gone) async {
    _stale = false;
    final RepertoireListing listing;
    try {
      listing = await _files.list();
    } on Object catch (error) {
      log.w('list the repertoires', error);
      return;
    }
    if (listing is! Repertoires) {
      _refs = const [];
      return;
    }
    final listed = [
      for (final folder in listing.folders)
        for (final chapter in folder.chapters)
          if (!chapter.heading.draft) chapter,
    ];
    final byFile = <String, List<ChapterRef>>{};
    for (final ref in listed) {
      (byFile[ref.path] ??= []).add(ref);
    }
    final indexed = <ChapterRef, RepertoireIndex>{};
    final revisions = <String, Revision>{};
    for (final chapters in byFile.values) {
      if (gone()) {
        _stale = true;
        return;
      }
      await _index(chapters, indexed, revisions);
    }
    _indexed = indexed;
    _revisions = revisions;
    _refs = List.unmodifiable(listed);
  }

  /// Indexes [chapters], the chapters one file holds, into [indexed]: what
  /// the last read made of them when the file's bytes are the same.
  Future<void> _index(
    List<ChapterRef> chapters,
    Map<ChapterRef, RepertoireIndex> indexed,
    Map<String, Revision> revisions,
  ) async {
    final file = chapters.first;
    switch (await _documents.open(file)) {
      case Opened(:final text, :final revision):
        if (_revisions[file.path] == revision &&
            chapters.every(_indexed.containsKey)) {
          for (final chapter in chapters) {
            indexed[chapter] = _indexed[chapter]!;
          }
          revisions[file.path] = revision;
          return;
        }
        try {
          final indexes = await _indexesIn(
            text,
            name: file.fileName,
            sections: [for (final chapter in chapters) chapter.section],
          );
          for (final (at, chapter) in chapters.indexed) {
            indexed[chapter] = indexes[at];
          }
          revisions[file.path] = revision;
        } on Object catch (error) {
          log.w('index ${file.path}', error);
        }
      case Absent():
        return;
      case Unreadable(:final detail):
        log.w('read ${file.path} for the index', detail);
    }
  }
}

/// What each of [sections] of the file [text] plays, the file parsed once
/// for all of them — on another isolate when it is big enough to hold the
/// window.
Future<List<RepertoireIndex>> _indexesIn(
  String text, {
  required String name,
  required List<String?> sections,
}) {
  List<RepertoireIndex> indexes() {
    final file = parseChapter(name: name, text: text);
    return [
      for (final section in sections) _indexOf(sectionView(file, section)),
    ];
  }

  return text.length < readOffThreadFrom
      ? Future.value(indexes())
      : Isolate.run(indexes);
}

RepertoireIndex _indexOf(SectionView view) =>
    RepertoireIndex.of(view.chapter.tree, view.chapter.side);
