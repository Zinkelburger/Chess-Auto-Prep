import 'dart:async';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_edit.dart';
import '../../chess/pgn/chapter_line.dart';
import '../../chess/pgn/chapter_sections.dart';
import '../../chess/pgn/games_written.dart';
import '../../chess/pgn/line_id_pins.dart';
import '../../chess/pgn/line_moves.dart';
import '../../chess/pgn/repertoire_import.dart';
import '../../diagnostics/log.dart';
import '../../storage/pending_writes.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/edit_scope.dart';
import '../../storage/reference_change.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/pgn_file_picker.dart';
import '../../storage/training_records.dart' as records;
import '../../ui/file_names.dart';
import '../../workspace/books.dart';
import '../../workspace/repertoire_catalog.dart';
import '../../workspace/document_saver.dart';
import '../../workspace/document_session.dart';
import '../../workspace/session_results.dart';
import 'library_state.dart';

/// The repertoire catalog and one user command at a time. Storage owns
/// durable references; the session owns open-file drafts and history.
/// Closed commands retain exact retry inputs and gate competing navigation.
final class Library extends ChangeNotifier {
  Library({
    required ChapterFiles files,
    required store.PgnDocumentStore documents,
    required DocumentSaver saver,
    required DocumentSession session,
    this.pendingWrites,
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

  /// The desktop's file dialog, then [importText] on what the file holds,
  /// named after the file. Null when the user closed the dialog without
  /// choosing.
  Future<LibraryResult?> importFile() async {
    final path = await _picker.pickPgn();
    if (path == null || _disposed) return null;
    return _run('import $path', () {
      final name = p.basenameWithoutExtension(path);
      return _importFile(
        path,
        name: importedName(name, fallback: importedFallback),
      );
    });
  }

  /// [text] as a new repertoire called [name], or [name] with ` (2)`,
  /// ` (3)`… when that is taken; [_importText] says what
  /// becomes of its variations and chapters.
  Future<LibraryResult> importText(String text, {required String name}) => _run(
    'import $name',
    () => _importText(text, name: importedName(name, fallback: name)),
  );

  /// How many names an import tries before it says the name is taken.
  static const _namesTried = 100;

  /// [name], then `name (2)`, `name (3)`…, leaving out every name a
  /// repertoire in the list has, compared without case as [_named] compares.
  ///
  /// The disk can still have one of them: a repertoire whose chapters were
  /// all deleted keeps its folder, because their recovery copies are in it,
  /// and the list does not show a folder with no chapter in it. The move into
  /// place is what finds that out, so an import tries these in turn.
  List<String> _freeNames(String name) {
    final names = <String>[];
    for (var n = 1; names.length < _namesTried; n++) {
      final candidate = n == 1 ? name : '$name ($n)';
      if (_named(candidate) == null) names.add(candidate);
    }
    return names;
  }

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

  /// Renames a file, or a course section's ChapterName and book references.
  Future<LibraryResult> renameChapter(ChapterRef ref, String name) =>
      _run('rename ${ref.path}', () async {
        if (ref.section case final section?) {
          final retry = _referenceRetries[(ref.path, section, name.trim())];
          if (retry != null) return retry();
          return _editFile(
            ref,
            (file) => sectionRenamed(file, section, name),
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
          return _editFile(ref, (file) => sectionRemoved(file, ref.section));
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
  /// chapter. [_moveLines] says in which order the two files
  /// are written.
  Future<LibraryResult> moveLines({
    required Set<int> games,
    required ChapterRef to,
    int? asSidelineOf,
  }) => _run(
    'move ${games.length} lines to ${to.path}',
    () => _moveLines(games: games, to: to, asSidelineOf: asSidelineOf),
  );

  /// The whole folder, in one rename.
  Future<LibraryResult> renameRepertoire(
    RepertoireFolder folder,
    String name,
  ) => _run('rename the repertoire ${folder.name}', () async {
    // The folder is not in the way of its own new name: on a case-sensitive
    // filesystem `kid` to `KID` is a rename like any other.
    if (_named(name, except: folder) != null) return const LibraryNameTaken();
    if (folder.chapters.any((c) => c.path == folder.path)) {
      return _relocate(
        folder.chapters.first.wholeFile,
        DocumentRef(p.join(_root, '$name.pgn')),
      );
    }
    return _renameFolder(folder, p.join(_root, name));
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
    _busy = true;
    if (!_disposed) notifyListeners();
    final LibraryResult result;
    try {
      result = await body();
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
    if (_disposed) return result;
    reportLibraryResult(action, result);
    await catalog.synchronize();
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
  }) async {
    final text =
        newChapterText(
          name: name,
          side: side,
          created: _now(),
          rootMoves: rootMoves,
        ) +
        games;
    return switch (await _store.create(ref, text)) {
      store.Created() => const LibraryDone(),
      store.Collision() => const LibraryNameTaken(),
      store.IoFailure(:final detail) => LibraryFailure(detail),
    };
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

  /// What the file at [path] holds, imported as [_importText] imports.
  Future<LibraryResult> _importFile(String path, {required String name}) async {
    switch (await _store.open(DocumentRef(path))) {
      case store.Opened(:final text):
        return _importText(text, name: name);
      case store.Absent():
        return const LibraryFileUnreadable('the file is not there');
      case store.Unreadable(:final detail):
        return LibraryFileUnreadable(detail);
    }
  }

  /// Imports variations as lines and course chapters as named sections.
  /// A private staging folder becomes visible only after its final rename.
  Future<LibraryResult> _importText(String text, {required String name}) async {
    // A course of a thousand games is read where the screen does not wait
    // for it; a pasted line is not worth the trip.
    final created = _now();
    ({ImportRead read, String? file}) course() {
      final read = readImport(text, created: created);
      return (
        read: read,
        file: read is ImportedChapters
            ? courseText(read, created: created)
            : null,
      );
    }

    final (:read, :file) = text.length < readOffThreadFrom
        ? course()
        : await Isolate.run(course);
    if (read is! ImportedChapters || file == null) {
      return const LibraryNothingToImport();
    }
    final folders = _freeNames(name);
    final staging = p.join(_root, '$stagingPrefix${_stagingId()}');
    final fileName = read.chapters.length == 1
        ? chapterFileNames(read.chapters).single
        : importedName(folders.first, fallback: 'Course');
    final ref = DocumentRef(p.join(staging, '$fileName.pgn'));
    final refused = switch (await _store.create(ref, file)) {
      store.Created() => null,
      store.Collision() => LibraryFailure('${ref.path} was already there'),
      store.IoFailure(:final detail) => LibraryFailure(detail),
    };
    if (refused != null) {
      await _files.removeStaging(staging);
      return refused;
    }
    return _placed(
      staging,
      folders,
      file: '$fileName.pgn',
      read: read,
      section: sectionsInText(file).first,
    );
  }

  /// [staging], holding [file], renamed into place under the first of
  /// [folders] that no folder on disk has taken.
  Future<LibraryResult> _placed(
    String staging,
    List<String> folders, {
    required String file,
    required ImportedChapters read,
    required String? section,
  }) async {
    for (final folder in folders) {
      final destination = p.join(_root, folder);
      switch (await _store.moveFolder(staging, destination)) {
        case store.FolderMoved():
          return LibraryAdded(
            ChapterRef.at(p.join(destination, file), section: section),
            chapters: read.chapters.length,
            lines: read.lines,
          );
        case store.FolderNameTaken():
          continue;
        case store.FolderMoveFailed(:final detail):
          await _files.removeStaging(staging);
          return LibraryFailure(detail);
      }
    }
    await _files.removeStaging(staging);
    return const LibraryNameTaken();
  }

  String _stagingId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// The chapter at [ref] renamed or moved to [to]. The workspace follows it
  /// when it has it open.
  Future<LibraryResult> _relocate(ChapterRef ref, DocumentRef to) =>
      _withRevision(ref, (revision) async {
        switch (await _store.move(ref, to, expected: revision)) {
          case store.Moved(:final training):
            if (_session.source?.path == ref.path) {
              _session.relocated(ChapterRef.at(to.path));
            }
            _books?.movedFile(ref.path, to.path);
            return LibraryDone(training: training);
          case store.Collision():
            return const LibraryNameTaken();
          case store.Conflict():
            return const LibraryStale();
          case store.IoFailure(:final detail):
            return LibraryFailure(detail);
        }
      });

  /// The chapter at [ref] to the recovery folder. The workspace closes it
  /// when it has it open.
  Future<LibraryResult> _remove(ChapterRef ref) =>
      _withRevision(ref, (revision) async {
        switch (await _store.delete(ref, expected: revision)) {
          case store.Deleted(:final training):
            if (_session.source?.path == ref.path) _session.closed();
            return LibraryDone(training: training);
          case store.Conflict():
            return const LibraryStale();
          case store.IoFailure(:final detail):
            return LibraryFailure(detail);
        }
      });

  /// The folder moves whole, in one rename: its chapters, the raw-game
  /// sidecars written beside them and the generation bundles under it. A
  /// chapter-at-a-time rename that stopped half way would split one
  /// repertoire across two folders and strand the rest of its files in the
  /// one that then vanishes from the list.
  Future<LibraryResult> _renameFolder(
    RepertoireFolder folder,
    String to,
  ) async {
    final open = _session.source;
    if (open == null || !p.isWithin(folder.path, open.path)) {
      return _movedFolder(folder.path, to);
    }
    // The chapter in the workspace is inside the folder, so its autosave is
    // held still for the length of the move, as its own rename holds it.
    return await _saver.holdStill((_) => _movedFolder(folder.path, to)) ??
        const LibraryBusy();
  }

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

  Future<LibraryResult> _movedFolder(String from, String to) async {
    switch (await _store.moveFolder(from, to)) {
      case store.FolderMoved(:final training):
        _followedFolder(from, to);
        _books?.movedFolder(from, to);
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

  /// Moves the lines at [games] of the open chapter into [to]: as lines of
  /// their own, or folded into the line at [asSidelineOf] there as
  /// variations.
  ///
  /// Two files, two saves, in the safe order: the lines are written into
  /// [to] first, against the revision it was read at, and only then taken
  /// out of the open chapter. A refusal on the way in changes nothing; a
  /// refusal on the way out leaves the lines in both files and says so,
  /// which is a duplicate the user can see rather than a loss they cannot.
  /// Within one chapter — a line dropped on another line of the same file —
  /// it is one document folded and then trimmed, through the session.
  Future<LibraryResult> _moveLines({
    required Set<int> games,
    required ChapterRef to,
    int? asSidelineOf,
  }) async {
    final chapter = _session.chapter;
    final from = _session.source;
    if (chapter == null || from == null) {
      return const LibraryFailure('there is no chapter open to move from');
    }
    final moving = games.where((g) => g != asSidelineOf || to != from).toSet();
    final lines = [
      for (final game in moving.toList()..sort())
        if (game >= 0 && game < chapter.lines.length) chapter.lines[game],
    ];
    if (lines.isEmpty) return const LibraryDone();
    if (to == from) return _foldedHere(moving, asSidelineOf);
    if (to.path == from.path) {
      // Another chapter of the same file: the lines keep their places and
      // take the other chapter's name, one edit to one file.
      if (asSidelineOf != null) {
        return const LibraryFailure(
          'a line can only be folded into a line of the chapter on the board',
        );
      }
      final places = _session.placesInFile(moving);
      final reason = _session.applyToFile(
        (file) => linesNamed(file, places, to.section),
      );
      if (reason != null) return LibraryFailure(reason);
      return _saved();
    }
    final written = await _writtenInto(to, lines, asSidelineOf);
    if (written != null) return written;
    // [moving] names games of the chapter as it was when the move began. The
    // user may have opened another chapter or edited this one while [to] was
    // being written, and those games of it are somebody else's lines.
    if (_disposed ||
        _session.source != from ||
        !identical(_session.chapter, chapter)) {
      return _notTakenOut(
        to,
        from,
        '${from.name} changed while they were written',
      );
    }
    final reason = _session.apply((c) => linesTakenOut(c, games: moving));
    if (reason != null) return _notTakenOut(to, from, reason);
    if (await _saved() is LibraryDone) return const LibraryDone();
    return _notTakenOut(to, from, '${from.name} could not be saved');
  }

  /// The lines went into [to] and are still in [from]: a duplicate the user
  /// can see, where the other order of the two saves could lose them.
  LibraryFailure _notTakenOut(ChapterRef to, ChapterRef from, String why) =>
      LibraryFailure(
        'the lines were added to ${to.name} but not taken out of '
        '${from.name}: $why',
      );

  /// One line folded into another of the open chapter, then taken out.
  LibraryResult _foldedHere(Set<int> games, int? host) {
    if (host == null) return const LibraryDone();
    for (final game in games) {
      final reason = _session.apply(
        (c) => lineGraftedInto(c, host: host, line: c.lines[game]),
      );
      if (reason != null) return LibraryFailure(reason);
    }
    final reason = _session.apply((c) => linesTakenOut(c, games: games));
    return reason == null ? const LibraryDone() : LibraryFailure(reason);
  }

  /// Puts [lines] into [to] on disk, or answers why it could not.
  Future<LibraryResult?> _writtenInto(
    ChapterRef to,
    List<ChapterLine> lines,
    int? host,
  ) async {
    final read = await _store.open(to);
    if (read is! store.Opened) {
      return LibraryFailure('${to.name} could not be read');
    }
    final file = await readChapter(name: to.fileName, text: read.text);
    final view = sectionView(file, to.section);
    // A line arriving as a game of its own still names the chapter it left.
    // It takes the name [to]'s games carry, or none, so a chapter file does
    // not turn into a course file holding a chapter named after the source.
    final arriving = host == null ? _namedAs(view.stamp, lines) : lines;
    if (arriving == null) {
      return const LibraryFailure(
        'the lines could not be given their chapter name',
      );
    }
    var target = view.chapter;
    var arranged = GamesArranged.of(
      GamesWritten(),
      before: target.lines.length,
    );
    for (final edit in _editsInto(arriving, host)) {
      switch (edit(target)) {
        case ChapterUnchanged():
          continue;
        case ChapterEditRefused(:final reason):
          return LibraryFailure(reason);
        case ChapterEdited(:final chapter, :final games):
          target = chapter;
          arranged = composedArrangement(arranged, games) ?? games;
      }
    }
    // A chapter of a course file goes back into its file.
    var text = writeChapter(target);
    if (!view.isWholeFile) {
      final back = spliced(view, target, arranged);
      if (back == null) {
        return const LibraryFailure(
          'the lines could not be given their chapter name',
        );
      }
      text = writeChapter(back.file);
      arranged = back.games;
    }
    return switch (await _store.save(
      to,
      text,
      expected: read.revision,
      scope: GamesRearranged(arranged),
    )) {
      store.Saved() => null,
      store.Conflict() => const LibraryStale(),
      store.SaveDidNotLand(:final detail) => LibraryFailure(detail),
    };
  }

  /// Edits through the workspace for an open file, otherwise against a fresh
  /// disk revision. [renamedTo] follows the selected section's new name.
  final _referenceRetries =
      <(String, String, String), Future<LibraryResult> Function()>{};

  Future<LibraryResult> _editFile(
    ChapterRef ref,
    ChapterEdit Function(Chapter file) edit, {
    String? renamedTo,
    ReferenceChanges? references,
  }) async {
    // By path: any chapter of the open file is the open file.
    if (_session.source?.path == ref.path) {
      return _editedOpen(ref, edit, renamedTo, references);
    }
    final read = await _store.open(ref);
    if (read is! store.Opened) {
      return LibraryFailure('${ref.name} could not be read');
    }
    final file = await readChapter(name: ref.fileName, text: read.text);
    // An open during this read transfers writing to the workspace.
    if (_session.source?.path == ref.path) {
      return _editedOpen(ref, edit, renamedTo, references);
    }
    switch (edit(file)) {
      case ChapterUnchanged():
        return const LibraryDone();
      case ChapterEditRefused(:final reason):
        return LibraryFailure(reason);
      case ChapterEdited(chapter: final edited, :final games):
        final pinned = withIdsPinned(file, edited, games);
        final scope = GamesRearranged(pinned.games, references: references);
        final text = writeChapter(pinned.chapter);
        Future<store.SaveResult> save() =>
            _store.save(ref, text, expected: read.revision, scope: scope);
        Future<store.SaveResult> coordinated() {
          if (_session.source?.path == ref.path) {
            return Future.value(
              const store.IoFailure(
                'Close this file before retrying its pending rename.',
              ),
            );
          }
          return _session.access.changing(
            ref.path,
            () => references == null || _books == null
                ? save()
                : _books.saveReferences(save),
          );
        }
        if (references == null) return _savedResult(await coordinated());
        // Exact retries retain the accepted bytes, revision and operation id.
        final key = (ref.path, ref.section!, renamedTo!);
        final obligation = pendingWrites?.accept<store.SaveResult>(
          resource: _store,
          label: 'Rename ${ref.name}',
          work: coordinated,
          problem: (result) => result is store.IoFailure ? result.detail : null,
        );
        Future<LibraryResult> retry() async {
          final result = obligation == null
              ? await coordinated()
              : await obligation.run();
          if (result is! store.IoFailure) _referenceRetries.remove(key);
          return _savedResult(
            result,
            retry: () => _run('retry rename ${ref.path}', retry),
          );
        }
        _referenceRetries[key] = retry;
        return retry();
    }
  }

  LibraryResult _savedResult(
    store.SaveResult result, {
    Future<LibraryResult> Function()? retry,
  }) => switch (result) {
    store.Saved() => const LibraryDone(),
    store.Conflict() => const LibraryStale(),
    store.SaveDidNotLand(:final detail) => LibraryFailure(
      detail,
      retry: result is store.IoFailure ? retry : null,
    ),
  };

  /// The workspace applies the edit; only the renamed section follows its name.
  Future<LibraryResult> _editedOpen(
    ChapterRef ref,
    ChapterEdit Function(Chapter file) edit,
    String? renamedTo,
    ReferenceChanges? references,
  ) async {
    final reason = _session.applyToFile(
      edit,
      section: _session.source == ref ? renamedTo : null,
      references: references,
    );
    if (reason != null) return LibraryFailure(reason);
    return _saved();
  }

  /// Settles autosave before the catalog reads the changed file; held edits
  /// remain explicitly drafts until the user keeps them.
  Future<LibraryResult> _saved() async {
    await _saver.flush();
    if (_session.hasHeldEdits) return const LibraryDone(draft: true);
    if (_saver.settled) return const LibraryDone();
    return switch (_saver.state) {
      SaveConflict() => const LibraryConflicted(),
      SaveFailed(:final detail) => LibraryFailure(detail),
      _ => const LibraryFailure('the change is on the board, not in the file'),
    };
  }

  /// Appends [lines], or grafts each into the game at [host].
  List<ChapterEdit Function(Chapter)> _editsInto(
    List<ChapterLine> lines,
    int? host,
  ) => host == null
      ? [(c) => linesAddedTo(c, lines: lines)]
      : [
          for (final line in lines)
            (c) => lineGraftedInto(c, host: host, line: line),
        ];

  /// Writes against the current revision, holding the saver for an open file.
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

  /// Holds the open file against autosave. A conflict requires reloading the
  /// workspace's revision, unlike a closed file's retryable [LibraryStale].
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

/// [lines] each naming [section] as its chapter, or no chapter when it is
/// null; null when one of them cannot be given the name.
List<ChapterLine>? _namedAs(String? section, List<ChapterLine> lines) {
  final named = <ChapterLine>[];
  for (final line in lines) {
    final renamed = sectionOf(line) == section
        ? line
        : withSection(line, section);
    if (renamed == null) return null;
    named.add(renamed);
  }
  return named;
}

/// A file name for each chapter, from its title, no two alike.
List<String> chapterFileNames(List<ImportedChapter> chapters) {
  final taken = <String>{};
  final names = <String>[];
  for (final (index, chapter) in chapters.indexed) {
    final base = importedName(chapter.title, fallback: 'Chapter ${index + 1}');
    var candidate = base;
    for (var n = 2; !taken.add(candidate.toLowerCase()); n++) {
      candidate = '$base ($n)';
    }
    names.add(candidate);
  }
  return names;
}
