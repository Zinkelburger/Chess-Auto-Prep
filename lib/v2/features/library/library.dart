import 'dart:async';

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
import 'library_report.dart';
import 'library_state.dart';

export 'library_state.dart';

/// The user's repertoires: the list, the search over it, and every change
/// that adds, renames, moves or removes one.
///
/// Every write goes through the document store, because that is what carries
/// the training records with it: a chapter's reviews, progress and history
/// are keyed by its path, and the store repoints them inside the same
/// operation. A chapter changes one file at a time; a repertoire renames as
/// one folder, so it cannot end up split in two, and deletes chapter by
/// chapter, because each one is quarantined separately.
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
       _root = root {
    _session.addListener(_followTheSession);
  }

  /// The name of the chapter a new repertoire starts with.
  static const firstChapter = 'Main';

  final ChapterFiles _files;
  final store.PgnDocumentStore _store;
  final DocumentSession _session;
  final DocumentSaver _saver;

  /// The `repertoires` folder, absolute.
  final String _root;

  LibraryState _state = const LibraryLoading();
  ChapterRef? _showing;
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

  /// The folders the listing could not read, whatever the search says: the
  /// panel names each one, because a repertoire missing from the list for a
  /// reason the user can fix is worth a line.
  List<UnreadableFolder> get unreadable => switch (_state) {
    LibraryLoaded(unreadable: final folders) => folders,
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
      Repertoires(:final folders, :final unreadable) => LibraryLoaded(
        folders,
        unreadable: unreadable,
      ),
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
  /// [rootMoves] is where its lines start when that is not the start: the
  /// position the user had on the board when they asked for it.
  Future<LibraryResult> createChapter(
    RepertoireFolder into,
    String name, {
    List<String> rootMoves = const [],
  }) => _run('create the chapter $name in ${into.name}', () async {
    final ref = DocumentRef(p.join(into.path, '$name.pgn'));
    return _created(ref, name, await _sideOf(into), rootMoves: rootMoves);
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

  /// The folder moves whole, in one rename: its chapters, the raw-game
  /// sidecars written beside them and the generation bundles under it. A
  /// chapter-at-a-time rename that stopped half way would split one
  /// repertoire across two folders and strand the rest of its files in the
  /// one that then vanishes from the list.
  Future<LibraryResult> renameRepertoire(
    RepertoireFolder folder,
    String name,
  ) => _run('rename the repertoire ${folder.name}', () async {
    // The folder is not in the way of its own new name: on a case-sensitive
    // filesystem `kid` to `KID` is a rename like any other.
    if (_named(name, except: folder) != null) return const LibraryNameTaken();
    Future<LibraryResult> move() =>
        _movedFolder(folder.path, p.join(_root, name));
    final open = _session.source;
    if (open == null || !p.isWithin(folder.path, open.path)) return move();
    // The chapter in the workspace is inside the folder, so its autosave is
    // held still for the length of the move, as its own rename holds it.
    return await _saver.holdStill((_) => move()) ?? const LibraryBusy();
  });

  /// Recoverable: each chapter goes to the recovery folder through the store,
  /// so its training rows follow it there and come back with it. A chapter
  /// that refuses stops the delete where it is — the ones already gone are in
  /// recovery — and the folder stays, because the rest is still in it.
  Future<LibraryResult> deleteRepertoire(RepertoireFolder folder) =>
      _run('delete the repertoire ${folder.name}', () async {
        final repointed = <records.RepointResult>[];
        for (final chapter in folder.chapters) {
          final result = await _remove(chapter);
          if (result case LibraryDone(:final training)) {
            repointed.add(training);
            continue;
          }
          return LibraryStoppedAt(chapter.name, result);
        }
        await _files.removeIfEmpty(folder.path);
        return LibraryDone(training: foldedRepoint(repointed));
      });

  /// Reads the open chapter from disk again, throwing the draft away. This is
  /// the way out of [LibraryConflicted]: the workspace takes the version that
  /// is on disk, and the change the user asked for can be made against it.
  Future<void> reloadOpenChapter() => _session.reloadFromDisk();

  Future<LibraryResult> _movedFolder(String from, String to) async {
    switch (await _store.moveFolder(from, to)) {
      case store.FolderMoved(:final training):
        _followedFolder(from, to);
        return LibraryDone(training: training);
      case store.FolderNameTaken():
        return const LibraryNameTaken();
      case store.FolderMoveFailed(:final detail):
        return LibraryFailure(detail);
    }
  }

  Future<LibraryResult> _created(
    DocumentRef ref,
    String name,
    Side side, {
    List<String> rootMoves = const [],
  }) async {
    final text = newChapterText(
      name: name,
      side: side,
      created: DateTime.now(),
      rootMoves: rootMoves,
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
            _followed(ref, ChapterRef.at(to.path));
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
  /// that it is still there — and the whole file, because a revision is a
  /// hash of the bytes and there is nothing cheaper to read.
  Future<LibraryResult> _withRevision(
    ChapterRef ref,
    Future<LibraryResult> Function(Revision revision) write,
  ) async {
    if (_session.source == ref) return _held(write);
    switch (await _store.open(ref)) {
      case store.Opened(:final revision):
        // The user may have opened this very chapter while it was being read,
        // and from here on its writes belong behind the saver's hold.
        if (_session.source == ref) return _held(write);
        return write(revision);
      case store.Absent():
        return const LibraryStale();
      case store.Unreadable(:final detail):
        log.w('read ${ref.path} before changing it', detail);
        return LibraryFailure(detail);
    }
  }

  /// Runs [write] with the open chapter held still by its saver.
  ///
  /// The revision it writes against is the saver's, so a refusal means the
  /// file changed under the workspace. Trying again cannot help while the
  /// workspace still holds the old revision, which is why that is a result of
  /// its own rather than the retryable [LibraryStale].
  Future<LibraryResult> _held(
    Future<LibraryResult> Function(Revision revision) write,
  ) async {
    final result = await _saver.holdStill(write);
    if (result == null) return const LibraryBusy();
    return result is LibraryStale ? const LibraryConflicted() : result;
  }

  /// The workspace follows the chapter it has open. The user may have opened
  /// another one while this change was in flight, which is why the file it
  /// started on is checked again rather than remembered.
  void _followed(ChapterRef ref, ChapterRef to) {
    if (_session.source == ref) _session.relocated(to);
  }

  /// The workspace follows a chapter whose whole folder moved under it.
  void _followedFolder(String from, String to) {
    final open = _session.source;
    if (open == null || !p.isWithin(from, open.path)) return;
    _session.relocated(
      ChapterRef.at(p.join(to, p.relative(open.path, from: from))),
    );
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
      if (!_disposed) notifyListeners();
    }
    if (_disposed) return result;
    reportLibraryResult(action, result);
    await refresh();
    return result;
  }

  /// The repertoire called [name], compared without case because a user who
  /// has `KID` did not mean to make a second `kid`. [except] is the folder
  /// being renamed, which is never in the way of its own name.
  RepertoireFolder? _named(String name, {RepertoireFolder? except}) {
    final wanted = name.toLowerCase();
    for (final folder in repertoires) {
      if (folder.path == except?.path) continue;
      if (folder.name.toLowerCase() == wanted) return folder;
    }
    return null;
  }

  /// The side [folder] trains, from the first chapter that can be read.
  /// A folder nobody can read is White, which is what an unmarked chapter is.
  Future<Side> _sideOf(RepertoireFolder folder) async {
    for (final chapter in folder.chapters) {
      if (await _store.open(chapter) case store.Opened(:final text)) {
        return chapterSide(text);
      }
    }
    return Side.white;
  }

  LibraryLoadFailed _loadFailed(String detail) {
    log.w('list the repertoires under $_root', detail);
    return LibraryLoadFailed(detail);
  }

  void _set(LibraryState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  /// The workspace opened a chapter this list does not have, so the list is
  /// out of date: saving a copy of a document that can take no more words
  /// hands the session to the copy, and that file was written a moment ago.
  /// Reading the folders again is what puts it in the list and selects it.
  void _followTheSession() {
    final open = _session.source;
    if (open == _showing) return;
    _showing = open;
    if (open == null || listsChapter(_state, open.path)) return;
    unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _session.removeListener(_followTheSession);
    super.dispose();
  }
}
