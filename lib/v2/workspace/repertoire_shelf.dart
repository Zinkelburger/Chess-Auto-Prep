import 'dart:isolate';

import 'package:flutter/foundation.dart';

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
final class RepertoireShelf extends ChangeNotifier {
  RepertoireShelf({required this._files, required this._documents});

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
  bool _disposed = false;
  Future<_ReadResult>? _reading;
  var _generation = 0;
  var _version = 0;
  String? _problem;

  /// Why the last read failed, when it did; the previous index stays.
  String? get problem => _problem;
  int get version => _version;

  /// The repertoire chapters in folder order, drafts left out, as last
  /// listed.
  List<ChapterRef> get refs => _refs;

  /// Whether the files must be read again before they are believed: they
  /// changed, or a read of them has not finished.
  bool get stale => _disposed || _stale || _reading != null;

  /// [ref]'s index in the last complete snapshot, or null if it was absent.
  RepertoireIndex? indexOf(ChapterRef ref) => _indexed[ref];

  /// The files changed on disk: they are read again the next time someone
  /// reads, and only the ones whose bytes changed are parsed again.
  void forget() {
    _generation++;
    _stale = true;
    _problem = null;
    if (!_disposed) notifyListeners();
  }

  /// Reads until nothing is stale, so a change that lands while the files
  /// are being read is read too. [gone] stops it early.
  Future<void> read({required bool Function() gone}) async {
    bool cancelled() => _disposed || gone();
    while (!cancelled()) {
      final reading = _reading;
      if (reading != null) {
        if (await reading == _ReadResult.failed) return;
      } else if (_stale) {
        final result = await (_reading = _readOnce(cancelled).whenComplete(() {
          _reading = null;
          if (!_disposed) notifyListeners();
        }));
        if (result == _ReadResult.failed) return;
      } else {
        return;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  Future<_ReadResult> _readOnce(bool Function() gone) async {
    final generation = _generation;
    try {
      final listing = await _files.list();
      if (gone() || generation != _generation) return _ReadResult.superseded;
      if (listing is! Repertoires) {
        throw StateError((listing as RepertoiresUnreadable).detail);
      }
      // A folder that cannot be read is left out, as the list leaves it
      // out; the rest of the book is still worth reading.
      for (final folder in listing.unreadable) {
        log.w('read ${folder.path} for the index', folder.detail);
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
        await _index(chapters, indexed, revisions);
        if (gone() || generation != _generation) return _ReadResult.superseded;
      }
      // A file changed while this read went on is told to [forget], which
      // reads again; there is nothing to check here first.
      _indexed = indexed;
      _revisions = revisions;
      _refs = List.unmodifiable([
        for (final ref in listed)
          if (indexed.containsKey(ref)) ref,
      ]);
      _stale = false;
      _problem = null;
      _version++;
      return _ReadResult.committed;
    } on Object catch (error) {
      if (gone() || generation != _generation) return _ReadResult.superseded;
      log.w('read the repertoire index', error);
      _problem = '$error';
      _stale = true;
      return _ReadResult.failed;
    }
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
      // A chapter gone or unreadable is left out of the book, not the
      // reason there is no book.
      case Absent():
        return;
      case Unreadable(:final detail):
        log.w('read ${file.path} for the index', detail);
    }
  }
}

enum _ReadResult { committed, superseded, failed }

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
