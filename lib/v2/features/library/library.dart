import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter_sections.dart';
import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/pgn_file_picker.dart';
import '../../ui/file_names.dart';
import '../../workspace/document_session.dart';
import 'library_report.dart';
import 'library_state.dart';
import 'library_writes.dart';

export 'library_state.dart';
export 'library_writes.dart' show LibraryWrites;

/// The user's repertoires: the list, the search over it, and the one change
/// at a time that adds, renames, moves or removes one.
///
/// How a change lands on disk is [LibraryWrites]'s; this owner decides
/// whether it may run — one at a time ([busy]), under a name no other
/// repertoire has — and reads the list again after each of them, so what
/// the screen shows is what the disk holds rather than what this owner
/// believes it did.
final class Library extends ChangeNotifier {
  Library({
    required ChapterFiles files,
    required LibraryWrites writes,
    required DocumentSession session,
    required PgnFilePicker picker,
    required String root,
  }) : _files = files,
       _writes = writes,
       _session = session,
       _picker = picker,
       _root = root {
    _session.addListener(_followTheSession);
  }

  /// The name of the chapter a new repertoire starts with.
  static const firstChapter = 'Main';

  /// What a repertoire imported from the clipboard is called.
  static const pastedName = 'Pasted repertoire';

  /// What a repertoire imported from a file whose name cannot be a folder's
  /// is called.
  static const importedFallback = 'Imported repertoire';

  final ChapterFiles _files;
  final LibraryWrites _writes;
  final DocumentSession _session;
  final PgnFilePicker _picker;

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
  /// and what every other mode can already open. With no [side] the chapter
  /// does not say whose it is, and the workspace asks once when it opens.
  Future<LibraryResult> createRepertoire(String name, [Side? side]) =>
      _run('create the repertoire $name', () async {
        if (_named(name) != null) return const LibraryNameTaken();
        final ref = DocumentRef(p.join(_root, name, '$firstChapter.pgn'));
        final result = await _writes.create(ref, name, side);
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
      final folder = _freeName(importedName(name, fallback: importedFallback));
      return _writes.importFile(path, folder: folder);
    });
  }

  /// [text] as a new repertoire called [name], or [name] with ` (2)`,
  /// ` (3)`… when that is taken; [LibraryWrites.importText] says what
  /// becomes of its variations and chapters.
  Future<LibraryResult> importText(String text, {required String name}) =>
      _run('import $name', () {
        final folder = _freeName(importedName(name, fallback: name));
        return _writes.importText(text, folder: folder);
      });

  /// [name], or the first of `name (2)`, `name (3)`… that no repertoire in
  /// the list has, compared without case as [_named] compares.
  String _freeName(String name) {
    var candidate = name;
    for (var n = 2; _named(candidate) != null; n++) {
      candidate = '$name ($n)';
    }
    return candidate;
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
    final side = await _writes.sideOf(into);
    return _writes.create(ref, name, side, rootMoves: rootMoves);
  });

  /// A chapter file is renamed on disk; a chapter of a course file is its
  /// games' `[ChapterName]`, so renaming it rewrites that tag and nothing
  /// else. The games of a course file that name no chapter are called after
  /// the file, so renaming them renames the file.
  Future<LibraryResult> renameChapter(ChapterRef ref, String name) =>
      _run('rename ${ref.path}', () {
        if (ref.section case final section?) {
          return _writes.editFile(
            ref,
            (file) => sectionRenamed(file, section, name),
            section: name.trim(),
          );
        }
        final to = p.join(p.dirname(ref.path), '$name.pgn');
        return _writes.relocate(ref, DocumentRef(to));
      });

  /// A chapter file moves to the other repertoire. A chapter of a course
  /// file is part of that file and goes where the file goes.
  Future<LibraryResult> moveChapter(ChapterRef ref, RepertoireFolder to) =>
      _run('move ${ref.path} to ${to.name}', () async {
        if (_sharesFile(ref)) {
          return const LibraryFailure(
            'a chapter of a course file moves with its file',
          );
        }
        final target = p.join(to.path, p.basename(ref.path));
        return _writes.relocate(ref, DocumentRef(target));
      });

  /// A chapter file goes to the recovery folder; a chapter of a course file
  /// is its games, which are taken out of the file — undo puts them back —
  /// and the file's other chapters stay.
  Future<LibraryResult> deleteChapter(ChapterRef ref) =>
      _run('delete ${ref.path}', () {
        if (_sharesFile(ref)) {
          return _writes.editFile(
            ref,
            (file) => sectionRemoved(file, ref.section),
          );
        }
        return _writes.remove(ref);
      });

  /// Whether [ref] is one of several chapters its file holds by tag.
  bool _sharesFile(ChapterRef ref) =>
      ref.section != null ||
      repertoires
              .expand((folder) => folder.chapters)
              .where((chapter) => chapter.path == ref.path)
              .length >
          1;

  /// Moves the lines at [games] of the open chapter into [to], or into the
  /// line at [asSidelineOf] there. This is what dropping lines on a chapter,
  /// or on a line, does — and how proposed lines are accepted into a real
  /// chapter. [LibraryWrites.moveLines] says in which order the two files
  /// are written.
  Future<LibraryResult> moveLines({
    required Set<int> games,
    required ChapterRef to,
    int? asSidelineOf,
  }) => _run(
    'move ${games.length} lines to ${to.path}',
    () => _writes.moveLines(games: games, to: to, asSidelineOf: asSidelineOf),
  );

  /// The whole folder, in one rename.
  Future<LibraryResult> renameRepertoire(
    RepertoireFolder folder,
    String name,
  ) => _run('rename the repertoire ${folder.name}', () async {
    // The folder is not in the way of its own new name: on a case-sensitive
    // filesystem `kid` to `KID` is a rename like any other.
    if (_named(name, except: folder) != null) return const LibraryNameTaken();
    return _writes.renameFolder(folder, p.join(_root, name));
  });

  /// Every chapter to the recovery folder, then the folder when it is empty.
  Future<LibraryResult> deleteRepertoire(RepertoireFolder folder) => _run(
    'delete the repertoire ${folder.name}',
    () => _writes.deleteFolder(folder),
  );

  /// Reads the open chapter from disk again, throwing the draft away. This is
  /// the way out of [LibraryConflicted]: the workspace takes the version that
  /// is on disk, and the change the user asked for can be made against it.
  Future<void> reloadOpenChapter() => _session.reloadFromDisk();

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
