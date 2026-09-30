import 'package:path/path.dart' as p;

import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/operation_id.dart';
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
/// failed is simply asked for again, against the disk as it is then. The one
/// thing kept is a change of the open chapter that the store recorded and
/// did not finish ([LibraryUnfinished]): the recovery gate carries it out at
/// a later access, and the workspace follows it then ([followPending]).
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

  /// The change of the open chapter still owed, and the follow of it that is
  /// running; see [followPending].
  _Owed? _owed;
  Future<bool>? _following;

  /// The chapter at [ref] renamed or moved to [to]. The workspace follows it
  /// when it has it open.
  Future<LibraryResult> move(ChapterRef ref, DocumentRef to) async {
    if (_owed != null) await followPending();
    return _changing(
      ref.path,
      to.path,
      folders: false,
      () => _withRevision(ref, (revision) async {
        final id = newOperationId();
        final moved = await _referencesFollow(
          () => _store.move(ref, to, expected: revision, operationId: id),
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
          case store.Unfinished(:final detail):
            _owe(_Owed(_Change.move, ref.path, to.path, id, revision));
            return LibraryUnfinished(detail);
          case store.IoFailure(:final detail):
            return LibraryFailure(detail);
        }
      }),
    );
  }

  /// The chapter at [ref] to the recovery folder. The workspace closes it
  /// when it has it open.
  Future<LibraryResult> delete(ChapterRef ref) async {
    if (_owed != null) await followPending();
    return _changing(
      ref.path,
      ref.path,
      folders: false,
      () => _withRevision(ref, (revision) async {
        final id = newOperationId();
        final deleted = await _referencesFollow(
          () => _store.delete(ref, expected: revision, operationId: id),
          failed: store.IoFailure.new,
        );
        switch (deleted) {
          case store.Deleted(:final training):
            if (_session.source?.path == ref.path) _session.closed();
            return LibraryDone(training: training);
          case store.Conflict():
            return const LibraryStale();
          case store.Unfinished(:final detail):
            _owe(_Owed(_Change.delete, ref.path, ref.path, id, revision));
            return LibraryUnfinished(detail);
          case store.IoFailure(:final detail):
            return LibraryFailure(detail);
        }
      }),
    );
  }

  /// The folder moves whole, in one rename: its chapters, the raw-game
  /// sidecars written beside them and the generation bundles under it. A
  /// chapter-at-a-time rename that stopped half way would split one
  /// repertoire across two folders and strand the rest of its files in the
  /// one that then vanishes from the list.
  Future<LibraryResult> renameFolder(String from, String to) async {
    if (_owed != null) await followPending();
    return _changing(from, to, folders: true, () async {
      final open = _session.source;
      if (open == null || !p.isWithin(from, open.path)) {
        return _movedFolder(from, to, null);
      }
      // The chapter in the workspace is inside the folder, so its autosave
      // is held still for the length of the move, as its own rename holds
      // it.
      return await _saver.holdStill(
            (revision) => _movedFolder(from, to, revision),
          ) ??
          const LibraryBusy();
    });
  }

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

  /// [open] is the revision of the open chapter when the folder holds it.
  Future<LibraryResult> _movedFolder(
    String from,
    String to,
    Revision? open,
  ) async {
    final id = newOperationId();
    final moved = await _referencesFollow(
      () => _store.moveFolder(from, to, operationId: id),
      failed: store.FolderMoveFailed.new,
    );
    switch (moved) {
      case store.FolderMoved(:final training):
        _followedFolder(from, to);
        return LibraryDone(training: training);
      case store.FolderNameTaken():
        return const LibraryNameTaken();
      case store.FolderMoveUnfinished(:final detail):
        if (open != null) _owe(_Owed(_Change.folder, from, to, id, open));
        return LibraryUnfinished(detail);
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

  /// Moves the workspace after the change of the open chapter that the store
  /// recorded and did not finish, once the recovery gate has carried it out:
  /// renamed or moved, the chapter is shown where it now is; deleted, it is
  /// closed. Whether the file left its name under that change — false when
  /// none is owed or the file is still there, and then saves go on going to
  /// it. Asked when a save finds the file gone ([DocumentSaver.owesMove]),
  /// after each change to the catalog and before the next change of a file.
  ///
  /// The store is asked again under the change's own id only once the file
  /// has left, which it answers from its receipt when the gate carried the
  /// change out; for a folder, only once the file is where the move put it,
  /// because a folder the gate set aside is still there to move. A file the
  /// gate set aside is still at its name and is never moved again from here:
  /// nothing here retries the disk.
  ///
  /// A delete that lands while words typed after it are waiting does not
  /// close the chapter: the save that finds the file gone stops as a
  /// conflict, and the words stay on the screen for Save a copy.
  Future<bool> followPending() {
    if (_owed == null) return Future.value(false);
    return _following ??= _follow()
        .onError<Object>((error, _) {
          log.w('follow the unfinished change of ${_owed?.from}', error);
          return false;
        })
        .whenComplete(() => _following = null);
  }

  Future<bool> _follow() async {
    final owed = _owed!;
    final open = _session.source?.path;
    // The workspace is on another document: nothing of it to follow now,
    // and the user may come back to it before the gate is done.
    if (open == null || !owed.holds(open)) return false;
    if (await _store.open(ChapterRef.at(open)) is! store.Absent) return false;
    final to = owed.change == _Change.folder
        ? p.join(owed.to, p.relative(open, from: owed.from))
        : owed.to;
    final landed = switch (owed.change) {
      _Change.move => switch (await _referencesFollow(
        () => _store.move(
          ChapterRef.at(owed.from),
          DocumentRef(owed.to),
          expected: owed.expected,
          operationId: owed.id,
        ),
        failed: store.IoFailure.new,
      )) {
        store.Moved() => _Landed.there,
        store.Collision() || store.Conflict() => _Landed.elsewhere,
        store.IoFailure() => await _landed(to, owed.expected),
      },
      _Change.folder => switch (await _store.open(ChapterRef.at(to))) {
        store.Opened(:final revision) when revision == owed.expected =>
          switch (await _referencesFollow(
            () => _store.moveFolder(owed.from, owed.to, operationId: owed.id),
            failed: store.FolderMoveFailed.new,
          )) {
            store.FolderMoved() || store.FolderMoveFailed() => _Landed.there,
            store.FolderNameTaken() => _Landed.elsewhere,
          },
        store.Unreadable() => _Landed.onItsWay,
        _ => _Landed.elsewhere,
      },
      _Change.delete => switch (await _referencesFollow(
        () => _store.delete(
          ChapterRef.at(owed.from),
          expected: owed.expected,
          operationId: owed.id,
        ),
        failed: store.IoFailure.new,
      )) {
        store.Deleted() => _Landed.there,
        store.Conflict() => _Landed.elsewhere,
        // Gone from its name and still recorded: the delete is on its way.
        store.IoFailure() => _Landed.onItsWay,
      },
    };
    if (_session.source?.path != open) {
      if (landed == _Landed.elsewhere) _settle(owed);
      return false;
    }
    switch (landed) {
      case _Landed.onItsWay:
        return true;
      case _Landed.elsewhere:
        // Not this change's doing: somebody else took the file.
        _settle(owed);
        return false;
      case _Landed.there:
        _settle(owed);
        switch (owed.change) {
          case _Change.move:
            _session.relocated(ChapterRef.at(owed.to));
          case _Change.folder:
            _followedFolder(owed.from, owed.to);
          case _Change.delete:
            if (!_saver.settled) return false;
            _session.closed();
        }
        return true;
    }
  }

  /// Where the file of a change the store cannot answer for yet — it is
  /// still recording what refers to the file — is: at [path] once the file
  /// itself has moved there with the bytes it had ([expected]), otherwise
  /// still on its way.
  Future<_Landed> _landed(String path, Revision expected) async =>
      switch (await _store.open(ChapterRef.at(path))) {
        store.Opened(:final revision) when revision == expected =>
          _Landed.there,
        _ => _Landed.onItsWay,
      };

  /// [owed] is what the open chapter waits for now, when it changes that.
  void _owe(_Owed owed) {
    final open = _session.source?.path;
    if (open == null || !owed.holds(open)) return;
    _owed = owed;
    _saver.owesMove(followPending);
  }

  /// Nothing is owed any more.
  void _settle(_Owed owed) {
    if (!identical(_owed, owed)) return;
    _owed = null;
    _saver.owesMove(null);
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

enum _Change { move, delete, folder }

/// Where an owed change left the file: where it was asked to go, not yet
/// there, or taken by someone else.
enum _Landed { there, onItsWay, elsewhere }

/// A change of the open chapter the store recorded and did not finish, as
/// it was asked for: an exact retry is known by [id], and the file by the
/// bytes it had ([expected]).
final class _Owed {
  _Owed(this.change, this.from, this.to, this.id, this.expected);

  final _Change change;
  final String from;
  final String to;
  final String id;
  final Revision expected;

  /// Whether the file at [path] is the one changed, or inside the folder.
  bool holds(String path) => p.equals(from, path) || p.isWithin(from, path);
}
