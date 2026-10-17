import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_edit.dart';
import '../../chess/pgn/chapter_sections.dart';
import '../../diagnostics/log.dart';
import '../../storage/pending_writes.dart';
import '../../storage/backup_history.dart';
import '../../storage/chapter_files.dart';
import '../../storage/deleted_chapters.dart';
import '../../storage/training_records.dart' as records;
import '../../storage/document_ref.dart';
import '../../storage/reference_change.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/pgn_file_picker.dart';
import '../../ui/file_names.dart';
import '../../workspace/books.dart';
import '../../workspace/repertoire_catalog.dart';
import '../../workspace/document_saver.dart';
import '../../workspace/document_session.dart';
import '../../workspace/session_results.dart';
import 'file_changes.dart';
import 'file_edits.dart';
import 'library_imports.dart';
import 'line_transfers.dart';
import 'library_state.dart';

/// The user's repertoires: the list, the search over it, and the one change
/// at a time that adds, renames, moves or removes one.
///
/// A change runs one at a time ([busy]), under a name no other repertoire
/// has, and the list is read again after each of them, so what the screen
/// shows is what the disk holds rather than what this owner believes it did.
/// Each change reads the file or folder it touches when it runs; one that
/// fails with a confirmed refusal changes nothing. An uncertain cross-file
/// line transfer retains its immutable command until its retry is resolved
/// or the user discards it.
///
/// Every write goes through the document store, because that is what carries
/// the training records and the books' references with it: a chapter's
/// reviews, progress and history are keyed by its path, and the store
/// repoints them inside the same operation. A chapter changes one file at a
/// time; a repertoire renames as one folder, so it cannot end up split in
/// two, and deletes chapter by chapter, because each one is quarantined
/// separately. The chapter open in the workspace is written only while its
/// saver holds it still, and the session is told where it went.
final class Library extends ChangeNotifier {
  Library({
    required ChapterFiles files,
    required store.PgnDocumentStore documents,
    required DocumentSaver saver,
    required DocumentSession session,
    this.pendingWrites,
    this.backupHistory,
    required PgnFilePicker picker,
    required String root,
    Books? books,
    RepertoireCatalog? catalog,
    DateTime Function() now = DateTime.now,
  }) : catalog = catalog ?? RepertoireCatalog(files: files, root: root),
       _ownsCatalog = catalog == null,
       _files = files,
       _books = books,
       _store = documents,
       _saver = saver,
       _session = session,
       _picker = picker,
       _root = root,
       _now = now {
    _session.addListener(_followTheSession);
    this.catalog.addListener(_catalogChanged);
  }

  /// The name of the chapter a new repertoire starts with.
  static const firstChapter = 'Main';

  /// What a repertoire imported from the clipboard is called.
  static const pastedName = 'Pasted repertoire';

  /// What a repertoire imported from a file whose name cannot be a folder's
  /// is called.
  static const importedFallback = 'Imported repertoire';

  final ChapterFiles _files;
  final store.PgnDocumentStore _store;
  final DocumentSaver _saver;
  final DocumentSession _session;
  final PgnFilePicker _picker;

  /// The `repertoires` folder, absolute.
  final String _root;

  /// The books, which follow a chapter or a repertoire that is renamed or
  /// moved; none in a test that has no books.
  final Books? _books;

  /// What a new chapter's heading says it was created on.
  final DateTime Function() _now;

  final RepertoireCatalog catalog;
  final bool _ownsCatalog;

  LibraryState _state = const LibraryLoading();
  ChapterRef? _showing;
  String _query = '';
  bool _busy = false;
  bool _disposed = false;
  late final _lineTransfers = LineTransfers(
    _store,
    _session,
    pendingWrites ?? PendingWrites(),
  );
  bool get hasPendingLineMove => _lineTransfers.pending;
  Future<LibraryResult> retryLineMove() =>
      _run('retry line move', _lineTransfers.retry);

  /// Gives up on a line move whose retry keeps failing, so the catalog takes
  /// changes again. False while its retry is still running.
  Future<bool> discardLineMove() async {
    final discarded = await _lineTransfers.discard();
    if (discarded && !_disposed) notifyListeners();
    return discarded;
  }

  LibraryState get state => _state;

  /// What the user typed into the search field.
  String get query => _query;

  /// A change to the catalog is in flight, so the row actions are off.
  /// Opening a chapter never waits for this.
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
  Future<void> refresh() => catalog.refresh();

  void _catalogChanged() {
    final listing = catalog.listing;
    if (listing == null) return;
    _set(switch (listing) {
      Repertoires(:final folders, :final unreadable) => LibraryLoaded(
        folders,
        unreadable: unreadable,
      ),
      RepertoiresUnreadable(:final detail) => _loadFailed(detail),
    });
  }

  /// A folder with one empty chapter in it, which is what the old app makes
  /// and what every other mode can already open. With no [side] the chapter
  /// does not say whose it is, and the workspace asks once when it opens.
  Future<LibraryResult> createRepertoire(String name, [Side? side]) =>
      _run('create the repertoire $name', () async {
        if (_named(name) != null) return const LibraryNameTaken();
        final ref = DocumentRef(p.join(_root, name, '$firstChapter.pgn'));
        final result = await _create(ref, name, side);
        if (result is! LibraryDone) return result;
        return LibraryAdded(ChapterRef.at(ref.path), chapters: 1, lines: 0);
      });

  /// Read one chapter for the outline search, without changing the workspace.
  Future<Chapter?> chapterForSearch(ChapterRef ref) async {
    final read = await _store.open(ref);
    if (read is! store.Opened) return null;
    return sectionView(
      await readChapter(name: ref.name, text: read.text),
      ref.section,
    ).chapter;
  }

  /// The desktop's file dialog, then [importText] on what the file holds,
  /// named after the file. Null when the user closed the dialog without
  /// choosing.
  Future<LibraryResult?> importFile() async {
    final path = await _picker.pickPgn();
    if (path == null || _disposed) return null;
    return importPath(path);
  }

  Future<LibraryResult> importPath(String path) => _run(
    'import $path',
    () => _imports.importFile(
      path,
      name: importedName(
        p.basenameWithoutExtension(path),
        fallback: importedFallback,
      ),
    ),
  );

  /// [text] as a new repertoire called [name], or [name] with ` (2)`,
  /// ` (3)`… when that is taken; [LibraryImports.importText] says what
  /// becomes of its variations and chapters.
  Future<LibraryResult> importText(String text, {required String name}) => _run(
    'import $name',
    () => _imports.importText(text, name: importedName(name, fallback: name)),
  );

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
    final side = await _sideOf(into);
    return _create(ref, name, side, rootMoves: rootMoves);
  });

  /// [board] — the analysis board — as a new chapter [name] of [into]. It
  /// keeps the board's side rather than the repertoire's: its lines were
  /// played for that side, and a chapter for the other one is still worth
  /// keeping somewhere the user can see it.
  Future<LibraryResult> saveBoard(
    RepertoireFolder into,
    String name,
    Chapter board,
  ) => _run('save the analysis board as $name in ${into.name}', () async {
    final ref = DocumentRef(p.join(into.path, '$name.pgn'));
    final games = writeChapter(board).substring(board.preamble.length);
    final result = await _create(ref, name, board.side, games: games);
    if (result is! LibraryDone) return result;
    return LibraryAdded(
      ChapterRef.at(ref.path),
      chapters: 1,
      lines: board.gameCount,
    );
  });

  /// A chapter file is renamed on disk; a chapter of a course file is its
  /// games' `[ChapterName]`, so renaming it rewrites that tag — and the
  /// books that name it, in the same save — and nothing else. The games of a
  /// course file that name no chapter are called after the file, so
  /// renaming them renames the file.
  Future<LibraryResult> renameChapter(ChapterRef ref, String name) =>
      _run('rename ${ref.path}', () async {
        if (ref.section case final section?) {
          return _edits.editFile(
            ref,
            (file) {
              // Asked again after a rename that landed without saying so.
              final names = sectionsIn(file.lines);
              if (!names.contains(section) && names.contains(name.trim())) {
                return const ChapterUnchanged();
              }
              return sectionRenamed(file, section, name);
            },
            renamedTo: name.trim(),
            references: ReferenceChanges([
              SectionRename(path: ref.path, from: section, to: name.trim()),
            ]),
          );
        }
        final to = p.join(p.dirname(ref.path), '$name.pgn');
        return _relocate(ref, DocumentRef(to));
      });

  /// A chapter file moves to the other repertoire. A chapter of a course
  /// file is part of that file and goes where the file goes.
  Future<LibraryResult> moveChapter(ChapterRef ref, RepertoireFolder to) =>
      _run('move ${ref.path} to ${to.name}', () async {
        if (sharesFile(ref)) {
          return const LibraryFailure(
            'a chapter of a course file moves with its file',
          );
        }
        final target = p.join(to.path, p.basename(ref.path));
        return _relocate(ref, DocumentRef(target));
      });

  /// A chapter file goes to the recovery folder; a chapter of a course file
  /// is its games, which are taken out of the file — undo puts them back —
  /// and the file's other chapters stay.
  Future<LibraryResult> deleteChapter(ChapterRef ref) =>
      _run('delete ${ref.path}', () {
        if (sharesFile(ref)) {
          return _edits.editFile(
            ref,
            (file) => sectionRemoved(file, ref.section),
          );
        }
        return _remove(ref);
      });

  /// Whether [ref] is one of several chapters its file holds by tag, so
  /// deleting it rewrites that file rather than moving one into recovery.
  bool sharesFile(ChapterRef ref) =>
      ref.section != null ||
      repertoires
              .expand((folder) => folder.chapters)
              .where((chapter) => chapter.path == ref.path)
              .length >
          1;

  /// Moves the lines at [games] of the open chapter into [to], or into the
  /// line at [asSidelineOf] there. This is what dropping lines on a chapter,
  /// or on a line, does — and how proposed lines are accepted into a real
  /// chapter. [FileEdits.moveLines] says in which order the two files
  /// are written.
  Future<LibraryResult> moveLines({
    required Set<int> games,
    required ChapterRef to,
    int? asSidelineOf,
  }) => _run('move ${games.length} lines to ${to.path}', () async {
    final chapter = _session.chapter;
    final from = _session.source;
    if (chapter == null || from == null) return _nothingOpen;
    return _edits.moveLines(
      chapter,
      from,
      games: games,
      to: to,
      asSidelineOf: asSidelineOf,
    );
  });

  /// Moves the lines at [games] of the open chapter into a new chapter
  /// [name] of [into], made first with the open chapter's side. Undoing the
  /// move brings the lines back and leaves the new chapter where it is.
  ///
  /// [games] are indexes into the chapter open at the click. When that
  /// chapter changed while the new one was being made, the indexes may
  /// name other lines, so nothing moves; a new chapter no line reached is
  /// taken away again rather than left empty.
  Future<LibraryResult> moveLinesToNewChapter({
    required Set<int> games,
    required RepertoireFolder into,
    required String name,
  }) => _run('move ${games.length} lines to a new chapter $name', () async {
    final chapter = _session.chapter;
    final from = _session.source;
    if (chapter == null || from == null) return _nothingOpen;
    final ref = ChapterRef.at(p.join(into.path, '$name.pgn'));
    final written = await _write(DocumentRef(ref.path), name, chapter.side);
    if (written is! store.Created) return _createResult(written);
    final moved =
        identical(_session.chapter, chapter) && _session.source == from
        ? await _edits.moveLines(chapter, from, games: games, to: ref)
        : _sourceChanged;
    // A move waiting for a retry, or recorded for recovery to finish, will
    // still write into the new chapter.
    if (moved is! LibraryDone &&
        moved is! LibraryUnfinished &&
        !hasPendingLineMove) {
      await _takeBack(ref, written.revision);
    }
    return moved;
  });

  /// Takes away the chapter [ref] a change made as [created] and then could
  /// not use. While the list has not shown it, nobody has seen it, so it
  /// goes without a recovery copy; one the list shows, or one that changed
  /// since, goes to recovery like any deleted chapter. What fails is logged
  /// and the empty chapter stays.
  Future<void> _takeBack(ChapterRef ref, Revision created) async {
    if (!listsChapter(_state, ref.path) &&
        await _files.removeUnused(ref, created)) {
      return;
    }
    reportLibraryResult(
      'remove the unused chapter ${ref.path}',
      await _remove(ref),
    );
  }

  static const _nothingOpen = LibraryFailure(
    'there is no chapter open to move from',
  );
  static const _sourceChanged = LibraryFailure(
    'the chapter changed before its lines could move',
  );

  /// The whole folder, in one rename.
  Future<LibraryResult> renameRepertoire(
    RepertoireFolder folder,
    String name,
  ) => _run('rename the repertoire ${folder.name}', () async {
    // The folder is not in the way of its own new name: on a case-sensitive
    // filesystem `kid` to `KID` is a rename like any other.
    final nameTaken = _named(name, except: folder) != null;
    if (folder.chapters.any((c) => c.path == folder.path)) {
      if (nameTaken) return const LibraryNameTaken();
      return _relocate(
        folder.chapters.first.wholeFile,
        DocumentRef(p.join(_root, '$name.pgn')),
      );
    }
    if (nameTaken) return const LibraryNameTaken();
    return _changes.renameFolder(folder.path, p.join(_root, name));
  });

  /// The deleted chapters still in recovery, most recently deleted first.
  /// Read on demand: nothing but the recovery view asks, and it asks again
  /// after each restore.
  Future<DeletedListing> deleted() => _files.deleted();

  /// Puts [chapter] back in the folder it was deleted from, under [name]
  /// (its old name when null). The store moves it, so its training rows
  /// come back with it; a chapter of that name already there is
  /// [LibraryNameTaken], and nothing is replaced.
  Future<LibraryResult> restoreChapter(
    DeletedChapter chapter, {
    String? name,
  }) => _run('restore ${chapter.path}', () {
    final to = DocumentRef(chapter.restoredAs(name));
    return _relocate(ChapterRef.at(chapter.path), to);
  });

  /// Every chapter to the recovery folder, then the folder when it is empty.
  Future<LibraryResult> deleteRepertoire(RepertoireFolder folder) =>
      _run('delete the repertoire ${folder.name}', () => _deleteFolder(folder));

  /// Reads the open chapter from disk again, throwing the draft away. This is
  /// the way out of [LibraryConflicted]: the workspace takes the version that
  /// is on disk, and the change the user asked for can be made against it.
  /// The file may be gone by now, which the answer says.
  Future<OpenResult> reloadOpenChapter() => _session.reloadFromDisk();

  /// One change at a time, then the list is read again: a half-applied change
  /// must be visible, and the store is the only thing that knows what landed.
  final PendingWrites? pendingWrites;
  final BackupHistory? backupHistory;

  Future<LibraryResult> _run(
    String action,
    Future<LibraryResult> Function() body,
  ) =>
      pendingWrites?.track(this, _perform(action, body), label: 'Library') ??
      _perform(action, body);

  Future<LibraryResult> _perform(
    String action,
    Future<LibraryResult> Function() body,
  ) async {
    if (_busy) return const LibraryBusy();
    if (hasPendingLineMove && action != 'retry line move') {
      return const LibraryFailure('Retry the unfinished line move first.');
    }
    _busy = true;
    notifyListeners();
    LibraryResult result;
    try {
      result = await body();
    } on Object catch (error) {
      result = LibraryFailure('$error');
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
    if (_disposed) return result;
    reportLibraryResult(action, result);
    await catalog.synchronize();
    // Reading the list is an access at which the recovery gate may have
    // carried out a change of the open chapter the store answered unfinished.
    await _changes.followPending();
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
    catalog.removeListener(_catalogChanged);
    if (_ownsCatalog) catalog.dispose();
    super.dispose();
  }

  // How each change lands on disk, and how the workspace follows it.

  /// A new chapter file at [ref] starting at [rootMoves], holding [games]
  /// — the text of whole games, or nothing for a chapter with no lines.
  Future<LibraryResult> _create(
    DocumentRef ref,
    String name,
    Side? side, {
    List<String> rootMoves = const [],
    String games = '',
  }) async => _createResult(
    await _write(ref, name, side, rootMoves: rootMoves, games: games),
  );

  Future<store.CreateResult> _write(
    DocumentRef ref,
    String name,
    Side? side, {
    List<String> rootMoves = const [],
    String games = '',
  }) {
    final text =
        newChapterText(
          name: name,
          side: side,
          created: _now(),
          rootMoves: rootMoves,
        ) +
        games;
    return _store.create(ref, text);
  }

  static LibraryResult _createResult(store.CreateResult result) =>
      switch (result) {
        store.Created() => const LibraryDone(),
        store.Collision() => const LibraryNameTaken(),
        store.IoFailure(:final detail) => LibraryFailure(detail),
      };

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

  late final _changes = FileChanges(
    store: _store,
    saver: _saver,
    session: _session,
    books: _books,
  );

  late final _imports = LibraryImports(
    store: _store,
    files: _files,
    root: _root,
    now: _now,
    named: _named,
  );

  late final _edits = FileEdits(
    store: _store,
    saver: _saver,
    session: _session,
    changes: _changes,
    lineTransfers: _lineTransfers,
  );

  /// The chapter at [ref] renamed or moved to [to].
  Future<LibraryResult> _relocate(ChapterRef ref, DocumentRef to) =>
      _changes.move(ref, to);

  /// The chapter at [ref] to the recovery folder.
  Future<LibraryResult> _remove(ChapterRef ref) => _changes.delete(ref);

  /// Recoverable: each chapter goes to the recovery folder through the store,
  /// so its training rows follow it there and come back with it. A chapter
  /// that refuses stops the delete where it is — the ones already gone are in
  /// recovery — and the folder stays, because the rest is still in it.
  ///
  /// A course file is listed once for each chapter it holds and goes to
  /// recovery once, whole.
  Future<LibraryResult> _deleteFolder(RepertoireFolder folder) async {
    final repointed = <records.RepointResult>[];
    final removed = <String>{};
    for (final chapter in folder.chapters) {
      final file = chapter.wholeFile;
      if (!removed.add(file.path)) continue;
      final result = await _remove(file);
      if (result case LibraryDone(:final training)) {
        repointed.add(training);
        continue;
      }
      return LibraryStoppedAt(file.name, result);
    }
    if (!folder.chapters.any((c) => c.path == folder.path)) {
      await _files.removeIfEmpty(folder.path);
    }
    return LibraryDone(training: foldedRepoint(repointed));
  }
}
