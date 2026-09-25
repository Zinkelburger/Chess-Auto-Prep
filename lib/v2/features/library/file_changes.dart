import 'package:path/path.dart' as p;

import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/reference_change.dart';
import '../../workspace/books.dart';
import '../../workspace/document_saver.dart';
import '../../workspace/document_session.dart';
import 'library_state.dart';

/// How a chapter file or a repertoire folder is moved or deleted on disk,
/// and how the workspace and the books follow it.
///
/// Each change reads the revision it acts on when it runs, so there is
/// nothing to remember between one attempt and the next: a change that
/// failed is simply asked for again, against the disk as it is then.
final class FileChanges {
  FileChanges({
    required this._store,
    required this._saver,
    required this._session,
    this._books,
  });

  final store.PgnDocumentStore _store;
  final DocumentSaver _saver;
  final DocumentSession _session;

  /// Null in a test that has no books.
  final Books? _books;

  /// The chapter at [ref] renamed or moved to [to]. The workspace follows it
  /// when it has it open.
  Future<LibraryResult> move(ChapterRef ref, DocumentRef to) => _changing(
    ref.path,
    to.path,
    folders: false,
    () => _withRevision(ref, (revision) async {
      final moved = await _referencesFollow(
        () => _store.move(ref, to, expected: revision),
        failed: store.IoFailure.new,
      );
      switch (moved) {
        case store.Moved(:final training):
          if (_session.source?.path == ref.path) {
            _session.relocated(ChapterRef.at(to.path));
          }
          return LibraryDone(training: training);
        case store.Collision():
          return const LibraryNameTaken();
        case store.Conflict():
          return const LibraryStale();
        case store.IoFailure(:final detail):
          return LibraryFailure(detail);
      }
    }),
  );

  /// The chapter at [ref] to the recovery folder. The workspace closes it
  /// when it has it open.
  Future<LibraryResult> delete(ChapterRef ref) => _changing(
    ref.path,
    ref.path,
    folders: false,
    () => _withRevision(ref, (revision) async {
      final deleted = await _referencesFollow(
        () => _store.delete(ref, expected: revision),
        failed: store.IoFailure.new,
      );
      switch (deleted) {
        case store.Deleted(:final training):
          if (_session.source?.path == ref.path) _session.closed();
          return LibraryDone(training: training);
        case store.Conflict():
          return const LibraryStale();
        case store.IoFailure(:final detail):
          return LibraryFailure(detail);
      }
    }),
  );

  /// The folder moves whole, in one rename: its chapters, the raw-game
  /// sidecars written beside them and the generation bundles under it. A
  /// chapter-at-a-time rename that stopped half way would split one
  /// repertoire across two folders and strand the rest of its files in the
  /// one that then vanishes from the list.
  Future<LibraryResult> renameFolder(String from, String to) =>
      _changing(from, to, folders: true, () async {
        final open = _session.source;
        if (open == null || !p.isWithin(from, open.path)) {
          return _movedFolder(from, to);
        }
        // The chapter in the workspace is inside the folder, so its autosave
        // is held still for the length of the move, as its own rename holds
        // it.
        return await _saver.holdStill((_) => _movedFolder(from, to)) ??
            const LibraryBusy();
      });

  /// Saves an edit to a file that is not open, with the books following
  /// the chapter names in [references] when there are any.
  Future<store.SaveResult> save(
    ChapterRef ref,
    ReferenceChanges? references,
    Future<store.SaveResult> Function() save,
  ) => _changing(
    ref.path,
    ref.path,
    folders: false,
    () => references == null
        ? save()
        : _referencesFollow(save, failed: store.IoFailure.new),
  );

  Future<LibraryResult> _movedFolder(String from, String to) async {
    final moved = await _referencesFollow(
      () => _store.moveFolder(from, to),
      failed: store.FolderMoveFailed.new,
    );
    switch (moved) {
      case store.FolderMoved(:final training):
        _followedFolder(from, to);
        return LibraryDone(training: training);
      case store.FolderNameTaken():
        return const LibraryNameTaken();
      case store.FolderMoveFailed(:final detail):
        return LibraryFailure(detail);
    }
  }

  /// The workspace follows a chapter whose whole folder moved under it. The
  /// user may have opened another one while the move was in flight, which is
  /// why the open file is read again rather than remembered.
  void _followedFolder(String from, String to) {
    final open = _session.source;
    if (open == null || !p.isWithin(from, open.path)) return;
    _session.relocated(
      ChapterRef.at(p.join(to, p.relative(open.path, from: from))),
    );
  }

  /// Runs [work] with opening [from] and [to] held off until it is over, so
  /// the workspace never reads a file half way through being moved.
  /// [folders] covers everything under the two paths.
  Future<T> _changing<T>(
    String from,
    String to,
    Future<T> Function() work, {
    required bool folders,
  }) {
    final access = _session.access;
    Future<T> change(String path, Future<T> Function() work) => folders
        ? access.changingFolder(path, work)
        : access.changing(path, work);
    return change(from, () => p.equals(from, to) ? work() : change(to, work));
  }

  /// The books name chapters by path, and the store rewrites those names
  /// with the file it moves. The books settle their own last edit first and
  /// read the result afterwards, so neither write undoes the other.
  Future<T> _referencesFollow<T>(
    Future<T> Function() write, {
    required T Function(String detail) failed,
  }) {
    final books = _books;
    return books == null
        ? write()
        : books.changeReferences(write, failed: failed);
  }

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
    // By path: any chapter of the open file is the open file.
    if (_session.source?.path == ref.path) return _held(write);
    switch (await _store.open(ref)) {
      case store.Opened(:final revision):
        // The user may have opened this very chapter while it was being read,
        // and from here on its writes belong behind the saver's hold.
        if (_session.source?.path == ref.path) return _held(write);
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
    if (result == null) {
      if (!_saver.settled) {
        return const LibraryFailure(
          'Save or recover the open draft before changing its file.',
        );
      }
      return const LibraryBusy();
    }
    return result is LibraryStale ? const LibraryConflicted() : result;
  }
}
