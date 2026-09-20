import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/training_records.dart' as records;
import '../../workspace/document_saver.dart';
import '../../workspace/document_session.dart';
import 'library_state.dart';

export 'library_state.dart';

/// The user's repertoires: the list, the search over it, and every change
/// that adds, renames, moves or removes one.
///
/// Every write goes through the document store, one chapter file at a time,
/// because that is what carries the training records with it: a chapter's
/// reviews, progress and history are keyed by its path, and the store
/// repoints them inside the same operation. So renaming a repertoire is
/// moving its chapters, and deleting one is deleting its chapters; the folder
/// itself is only what is left when they are gone.
///
/// One change at a time ([busy]). The list is read again after each of them,
/// so what the screen shows is what the disk holds rather than what this
/// owner believes it did.
final class Library extends ChangeNotifier {
  Library({
    required ChapterFiles files,
    required store.PgnDocumentStore documents,
    required DocumentSession session,
    required DocumentSaver saver,
    required String root,
  }) : _files = files,
       _store = documents,
       _session = session,
       _saver = saver,
       _root = root;

  /// The name of the chapter a new repertoire starts with.
  static const firstChapter = 'Main';

  final ChapterFiles _files;
  final store.PgnDocumentStore _store;
  final DocumentSession _session;
  final DocumentSaver _saver;

  /// The `repertoires` folder, absolute.
  final String _root;

  LibraryState _state = const LibraryLoading();
  String _query = '';
  int _refreshes = 0;
  bool _busy = false;
  bool _disposed = false;

  LibraryState get state => _state;

  /// What the user typed into the search field.
  String get query => _query;

  /// A change to the catalog is in flight, so the row actions are off.
  bool get busy => _busy;

  /// Every repertoire that was listed, whatever the search says: what a
  /// chapter can be moved into.
  List<RepertoireFolder> get repertoires => switch (_state) {
    LibraryLoaded(repertoires: final folders) => folders,
    _ => const [],
  };

  /// The repertoires whose name matches [query].
  List<RepertoireFolder> get visible {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return repertoires;
    return [
      for (final folder in repertoires)
        if (folder.name.toLowerCase().contains(needle)) folder,
    ];
  }

  void search(String query) {
    if (query == _query) return;
    _query = query;
    notifyListeners();
  }

  /// Reads the folders again. A refresh overtaken by a newer one discards its
  /// answer, so the list never goes back in time. A list already on screen
  /// stays there while the new one is read: a change the user just made
  /// should not blank the panel it was made in.
  Future<void> refresh() async {
    final ticket = ++_refreshes;
    if (_state is! LibraryLoaded) _set(const LibraryLoading());
    final listing = await _files.list();
    if (_disposed || ticket != _refreshes) return;
    _set(switch (listing) {
      Repertoires(:final folders) => LibraryLoaded(folders),
      RepertoiresUnreadable(:final detail) => _loadFailed(detail),
    });
  }

  /// A folder with one empty chapter in it, which is what the old app makes
  /// and what every other mode can already open.
  Future<LibraryResult> createRepertoire(String name, Side side) =>
      _run('create the repertoire $name', () async {
        if (_named(name) != null) return const LibraryNameTaken();
        final ref = DocumentRef(p.join(_root, name, '$firstChapter.pgn'));
        return _created(ref, name, side);
      });

  /// A chapter takes the side of the repertoire it is added to, read from a
  /// chapter already in it, so a Black repertoire does not grow a White one.
  Future<LibraryResult> createChapter(RepertoireFolder into, String name) =>
      _run('create the chapter $name in ${into.name}', () async {
        final ref = DocumentRef(p.join(into.path, '$name.pgn'));
        return _created(ref, name, await _sideOf(into));
      });

  Future<LibraryResult> renameChapter(ChapterRef ref, String name) =>
      _run('rename ${ref.path}', () {
        final to = p.join(p.dirname(ref.path), '$name.pgn');
        return _relocate(ref, DocumentRef(to));
      });

  Future<LibraryResult> moveChapter(ChapterRef ref, RepertoireFolder to) =>
      _run('move ${ref.path} to ${to.name}', () {
        final target = p.join(to.path, p.basename(ref.path));
        return _relocate(ref, DocumentRef(target));
      });

  Future<LibraryResult> deleteChapter(ChapterRef ref) =>
      _run('delete ${ref.path}', () => _remove(ref));

  /// Every chapter moves into the new folder, one store operation each, and
  /// the old folder goes once it is empty. A chapter that refuses stops the
  /// rename where it is: the ones already moved are where the user asked them
  /// to be, and the result names the one that did not follow.
  Future<LibraryResult> renameRepertoire(
    RepertoireFolder folder,
    String name,
  ) => _run('rename the repertoire ${folder.name}', () async {
    if (_named(name) != null) return const LibraryNameTaken();
    final target = p.join(_root, name);
    return _everyChapter(
      folder,
      (chapter) => _relocate(
        chapter,
        DocumentRef(p.join(target, p.basename(chapter.path))),
      ),
    );
  });

  /// Recoverable: each chapter goes to the recovery folder through the store,
  /// so its training rows follow it there and come back with it.
  Future<LibraryResult> deleteRepertoire(RepertoireFolder folder) => _run(
    'delete the repertoire ${folder.name}',
    () => _everyChapter(folder, _remove),
  );

  /// Runs [each] over the folder's chapters until one refuses, then takes the
  /// folder away if nothing is left in it.
  Future<LibraryResult> _everyChapter(
    RepertoireFolder folder,
    Future<LibraryResult> Function(ChapterRef) each,
  ) async {
    final repointed = <records.RepointResult>[];
    for (final chapter in folder.chapters) {
      final result = await each(chapter);
      if (result case LibraryDone(:final training)) {
        repointed.add(training);
        continue;
      }
      return LibraryStoppedAt(chapter.name, result);
    }
    await _files.removeIfEmpty(folder.path);
    return LibraryDone(training: _allOf(repointed));
  }

  Future<LibraryResult> _created(
    DocumentRef ref,
    String name,
    Side side,
  ) async {
    final text = newChapterText(
      name: name,
      side: side,
      created: DateTime.now(),
    );
    return switch (await _store.create(ref, text)) {
      store.Created() => const LibraryDone(),
      store.Collision() => const LibraryNameTaken(),
      store.IoFailure(:final detail) => LibraryFailure(detail),
    };
  }

  Future<LibraryResult> _relocate(ChapterRef ref, DocumentRef to) =>
      _withRevision(ref, (revision) async {
        switch (await _store.move(ref, to, expected: revision)) {
          case store.Moved(:final training):
            _followed(ref, _chapterAt(to));
            return LibraryDone(training: training);
          case store.Collision():
            return const LibraryNameTaken();
          case store.Conflict():
            return const LibraryStale();
          case store.IoFailure(:final detail):
            return LibraryFailure(detail);
        }
      });

  Future<LibraryResult> _remove(ChapterRef ref) =>
      _withRevision(ref, (revision) async {
        switch (await _store.delete(ref, expected: revision)) {
          case store.Deleted(:final training):
            _closedIfOpen(ref);
            return LibraryDone(training: training);
          case store.Conflict():
            return const LibraryStale();
          case store.IoFailure(:final detail):
            return LibraryFailure(detail);
        }
      });

  /// Runs [write] against the revision the chapter has now.
  ///
  /// The chapter open in the workspace is held still by its saver for the
  /// length of the operation, so a rename cannot land between an autosave and
  /// its answer. Any other chapter is read from disk, which is also the check
  /// that it is still there.
  Future<LibraryResult> _withRevision(
    ChapterRef ref,
    Future<LibraryResult> Function(Revision revision) write,
  ) async {
    if (_session.source == ref) {
      return await _saver.holdStill(write) ?? const LibraryStale();
    }
    switch (await _store.open(ref)) {
      case store.Opened(:final revision):
        return write(revision);
      case store.Absent():
        return const LibraryStale();
      case store.Unreadable(:final detail):
        log.w('read ${ref.path} before changing it', detail);
        return LibraryFailure(detail);
    }
  }

  /// The workspace follows the chapter it has open. The user may have opened
  /// another one while this change was in flight, which is why the file it
  /// started on is checked again rather than remembered.
  void _followed(ChapterRef ref, ChapterRef to) {
    if (_session.source == ref) _session.relocated(to);
  }

  void _closedIfOpen(ChapterRef ref) {
    if (_session.source == ref) _session.closed();
  }

  /// One change at a time, then the list is read again: a half-applied change
  /// must be visible, and the store is the only thing that knows what landed.
  Future<LibraryResult> _run(
    String action,
    Future<LibraryResult> Function() body,
  ) async {
    if (_busy) return const LibraryBusy();
    _busy = true;
    notifyListeners();
    final LibraryResult result;
    try {
      result = await body();
    } finally {
      _busy = false;
    }
    if (_disposed) return result;
    _report(action, result);
    await refresh();
    return result;
  }

  void _report(String action, LibraryResult result) {
    switch (result) {
      case LibraryDone() || LibraryBusy():
        return;
      case LibraryNameTaken():
        log.w(action, 'the name is taken');
      case LibraryStale():
        log.w(action, 'the file changed on disk');
      case LibraryFailure(:final detail):
        log.e(action, detail);
      case LibraryStoppedAt(:final chapter, :final cause):
        log.e(action, 'stopped at $chapter');
        _report('$action: $chapter', cause);
    }
  }

  RepertoireFolder? _named(String name) {
    final wanted = name.toLowerCase();
    for (final folder in repertoires) {
      if (folder.name.toLowerCase() == wanted) return folder;
    }
    return null;
  }

  /// The side [folder] trains, from the first chapter that can be read.
  /// A folder nobody can read is White, which is what an unmarked chapter is.
  Future<Side> _sideOf(RepertoireFolder folder) async {
    for (final chapter in folder.chapters) {
      if (await _store.open(chapter) case store.Opened(:final text)) {
        return parseChapter(name: chapter.name, text: text).side;
      }
    }
    return Side.white;
  }

  ChapterRef _chapterAt(DocumentRef ref) => ChapterRef(
    repertoire: p.basename(p.dirname(ref.path)),
    name: p.basenameWithoutExtension(ref.path),
    path: ref.path,
  );

  LibraryLoadFailed _loadFailed(String detail) {
    log.w('list the repertoires under $_root', detail);
    return LibraryLoadFailed(detail);
  }

  void _set(LibraryState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Every repoint folded into one answer: a problem if any chapter had one,
/// otherwise the rows that followed.
records.RepointResult _allOf(List<records.RepointResult> results) {
  var rows = 0;
  for (final result in results) {
    switch (result) {
      case records.Repointed(:final rowsChanged):
        rows += rowsChanged;
      case records.NothingToRepoint():
        continue;
      case records.Malformed() || records.IoFailure():
        return result;
    }
  }
  return rows == 0 ? const records.NothingToRepoint() : records.Repointed(rows);
}
