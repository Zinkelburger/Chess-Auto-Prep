/// State behind the outline panel: the outline of the open repertoire, which
/// folders are expanded, and every structural edit — each one a call to
/// [RepertoireOutlineService] followed by a rebuild, so the panel only ever
/// renders what is actually on disk.
///
/// The controller does not own the *active* chapter; the screen does (it is
/// what the board and PGN editor show). It is told the active chapter path so
/// it can highlight it and keep its folder expanded, and it reports edits that
/// change that path (rename, move, delete) through [onActiveChapterMoved] so
/// the screen can follow.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../utils/safe_change_notifier.dart';
import '../models/outline_rows.dart';
import '../models/repertoire_outline.dart';
import '../services/repertoire_outline_service.dart';

/// Result of an edit, for the panel to toast. [error] set means refused.
///
/// A successful edit that is worth a word carries a [message] ("Moved 3
/// lines to Sidelines"), and one that can be taken back carries [undo] — the
/// panel shows it as the toast's action. Undo is itself an edit, so it
/// returns an outcome too; it does not offer a redo.
class OutlineEditOutcome {
  final String? error;
  final String? message;
  final Future<OutlineEditOutcome> Function()? undo;

  const OutlineEditOutcome.ok() : error = null, message = null, undo = null;
  const OutlineEditOutcome.done({this.message, this.undo}) : error = null;
  const OutlineEditOutcome.failed(this.error) : message = null, undo = null;

  bool get ok => error == null;
}

class RepertoireOutlineController extends ChangeNotifier
    with SafeChangeNotifier {
  RepertoireOutlineController({
    RepertoireOutlineService? service,
    this.onActiveChapterMoved,
  }) : _service = service ?? RepertoireOutlineService();

  final RepertoireOutlineService _service;

  /// Called when an edit renamed, moved or deleted the active chapter file:
  /// the new path, or null when it no longer exists.
  final void Function(String? newPath)? onActiveChapterMoved;

  OutlineFolder? _outline;
  OutlineFolder? get outline => _outline;

  String? _rootPath;
  String? get rootPath => _rootPath;

  String? _activeChapterPath;
  String? get activeChapterPath => _activeChapterPath;

  bool _isWhite = true;
  bool get isWhite => _isWhite;

  bool _loading = false;
  bool get isLoading => _loading;

  String? _error;
  String? get error => _error;

  /// Bumped whenever the fold state ([_expanded], [_openChapters]) or the
  /// active chapter changes — the parts of the row list that are not the
  /// outline itself.  [rows] keys its cache on it.
  int _viewVersion = 0;

  OutlineRowCache? _rowCache;

  /// The visible rows of the panel for [filter], flattened once per
  /// (outline, fold state, filter) and reused across rebuilds.
  ///
  /// The panel used to walk the whole outline and build a widget per line on
  /// every rebuild — every cursor move, every search keystroke — which on a
  /// large course was thousands of allocations per arrow key.  Now the walk
  /// happens here, only when one of its inputs changed, and the panel renders
  /// the rows lazily.
  List<OutlineRow> rows(OutlineFilter filter) {
    final outline = _outline;
    if (outline == null) return const [];
    final cached = _rowCache;
    if (cached != null &&
        identical(cached.outline, outline) &&
        cached.viewVersion == _viewVersion &&
        cached.filter == filter) {
      return cached.rows;
    }
    final rows = OutlineRowBuilder(
      filter: filter,
      isExpanded: isExpanded,
      isChapterOpen: isChapterOpen,
      activeChapterPath: _activeChapterPath,
    ).build(outline);
    _rowCache = OutlineRowCache(
      outline: outline,
      viewVersion: _viewVersion,
      filter: filter,
      rows: rows,
    );
    return rows;
  }

  /// Folder paths currently expanded in the panel. The root is always open.
  final Set<String> _expanded = {};
  bool isExpanded(String folderPath) =>
      _rootPath != null && p.equals(folderPath, _rootPath!) ||
      _expanded.contains(folderPath);

  /// Chapters whose lines are unfolded in the panel.
  final Set<String> _openChapters = {};
  bool isChapterOpen(String chapterPath) => _openChapters.contains(chapterPath);

  int _epoch = 0;

  // ── Loading ────────────────────────────────────────────────────────────

  /// Point the controller at the repertoire folder holding [chapterPath] and
  /// (re)build. Also called with the same folder to refresh after the screen
  /// saved lines.
  Future<void> open({
    required String rootPath,
    required String? activeChapterPath,
    required bool isWhite,
  }) async {
    final changedRoot = _rootPath == null || !p.equals(_rootPath!, rootPath);
    _rootPath = rootPath;
    _isWhite = isWhite;
    if (changedRoot) {
      _expanded.clear();
      _openChapters.clear();
    }
    setActiveChapter(activeChapterPath, notify: false);
    await refresh();
  }

  void close() {
    _epoch++;
    _rootPath = null;
    _outline = null;
    _activeChapterPath = null;
    _expanded.clear();
    _openChapters.clear();
    _viewVersion++;
    notifyListeners();
  }

  /// Rebuild from disk. Cheap when nothing changed (lines are cached by
  /// mtime), so callers can refresh generously.
  Future<void> refresh() async {
    final root = _rootPath;
    if (root == null) return;
    final epoch = ++_epoch;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final built = await _service.build(
        root,
        trainingColor: _isWhite ? 'white' : 'black',
      );
      if (epoch != _epoch) return;
      _outline = built;
      _revealActive();
      _viewVersion++;
    } catch (e) {
      if (epoch != _epoch) return;
      _error = 'Could not read the repertoire folder.\n$e';
    } finally {
      if (epoch == _epoch) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Which chapter the board is showing. Its ancestors expand so it is
  /// visible, and its lines unfold.
  void setActiveChapter(String? chapterPath, {bool notify = true}) {
    _activeChapterPath = chapterPath;
    _revealActive();
    _viewVersion++;
    if (notify) notifyListeners();
  }

  void _revealActive() {
    final active = _activeChapterPath;
    final root = _rootPath;
    if (active == null || root == null) return;
    var dir = p.dirname(active);
    while (p.isWithin(root, dir)) {
      _expanded.add(dir);
      dir = p.dirname(dir);
    }
    _openChapters.add(active);
  }

  // ── View state ─────────────────────────────────────────────────────────

  void toggleFolder(String folderPath) {
    if (_rootPath != null && p.equals(folderPath, _rootPath!)) return;
    if (!_expanded.remove(folderPath)) _expanded.add(folderPath);
    _viewVersion++;
    notifyListeners();
  }

  void toggleChapter(String chapterPath) {
    if (!_openChapters.remove(chapterPath)) _openChapters.add(chapterPath);
    _viewVersion++;
    notifyListeners();
  }

  void setChapterOpen(String chapterPath, bool open) {
    if (open
        ? _openChapters.add(chapterPath)
        : _openChapters.remove(chapterPath)) {
      _viewVersion++;
      notifyListeners();
    }
  }

  // ── Edits ──────────────────────────────────────────────────────────────

  Future<OutlineEditOutcome> _edit(
    Future<OutlineEditOutcome> Function() body,
  ) async {
    try {
      final outcome = await body();
      await refresh();
      return outcome;
    } on OutlineEditException catch (e) {
      return OutlineEditOutcome.failed(e.message);
    } catch (e) {
      await refresh();
      return OutlineEditOutcome.failed('That did not work: $e');
    }
  }

  Future<OutlineEditOutcome> createChapter({
    required String folderPath,
    required String name,
  }) => _edit(() async {
    final chapter = await _service.createChapter(
      folderPath: folderPath,
      name: name,
      isWhite: _isWhite,
    );
    _expanded.add(folderPath);
    _openChapters.add(chapter.path);
    return const OutlineEditOutcome.ok();
  });

  /// A new chapter in [folderPath] holding the lines at [gameIndexes] of
  /// [fromChapterPath] — what dropping lines on a folder makes. Undo moves
  /// the lines back and removes the chapter.
  Future<OutlineEditOutcome> createChapterWithLines({
    required String folderPath,
    required String name,
    required String fromChapterPath,
    required Set<int> gameIndexes,
  }) => _edit(() async {
    final chapter = await _service.createChapter(
      folderPath: folderPath,
      name: name,
      isWhite: _isWhite,
    );
    _expanded.add(folderPath);
    _openChapters.add(chapter.path);
    final moved = await _moveLinesNoted(
      fromChapterPath: fromChapterPath,
      gameIndexes: gameIndexes,
      toChapterPath: chapter.path,
    );
    if (moved == null) {
      throw const OutlineEditException('Those lines are no longer there.');
    }
    final count = moved.landed.length;
    return OutlineEditOutcome.done(
      message:
          'Made "${chapter.name}" from $count line${count == 1 ? '' : 's'}.',
      undo: () => _edit(() async {
        // Only what was moved in is there, unless lines were added since;
        // then the chapter stays, emptied of the ones that came from here.
        final untouched =
            (_outline?.findChapter(chapter.path)?.lineCount ?? 0) ==
            moved.landed.length;
        await _service.moveLines(
          fromChapterPath: chapter.path,
          gameIndexes: moved.landed.toSet(),
          toChapterPath: fromChapterPath,
          toIndexes: moved.origin,
        );
        if (untouched) {
          await _service.deleteChapter(chapter.path);
          _openChapters.remove(chapter.path);
          if (_isActive(chapter.path)) {
            _activeChapterPath = fromChapterPath;
            onActiveChapterMoved?.call(fromChapterPath);
          }
        }
        _noteChapterChanged(fromChapterPath);
        return const OutlineEditOutcome.done(message: 'Moved the lines back.');
      }),
    );
  });

  Future<OutlineEditOutcome> createFolder({
    required String parentPath,
    required String name,
  }) => _edit(() async {
    final path = await _service.createFolder(
      parentPath: parentPath,
      name: name,
    );
    _expanded
      ..add(parentPath)
      ..add(path);
    return const OutlineEditOutcome.ok();
  });

  Future<OutlineEditOutcome> renameChapter(
    String chapterPath,
    String newName,
  ) => _edit(() async {
    final newPath = await _service.renameChapter(chapterPath, newName);
    _followActive(chapterPath, newPath);
    if (_openChapters.remove(chapterPath)) _openChapters.add(newPath);
    return const OutlineEditOutcome.ok();
  });

  Future<OutlineEditOutcome> renameFolder(String folderPath, String newName) =>
      _edit(() async {
        final newPath = await _service.renameFolder(folderPath, newName);
        _rekeyFolderState(folderPath, newPath);
        return const OutlineEditOutcome.ok();
      });

  Future<OutlineEditOutcome> moveChapter(
    String chapterPath,
    String targetFolderPath, {
    bool undoable = true,
  }) => _edit(() async {
    final from = p.dirname(chapterPath);
    final newPath = await _service.moveChapter(chapterPath, targetFolderPath);
    _followActive(chapterPath, newPath);
    if (_openChapters.remove(chapterPath)) _openChapters.add(newPath);
    _expanded.add(targetFolderPath);
    if (!undoable) return const OutlineEditOutcome.ok();
    return OutlineEditOutcome.done(
      message:
          'Moved "${p.basenameWithoutExtension(chapterPath)}" to '
          '${_folderLabel(targetFolderPath)}.',
      undo: () => moveChapter(newPath, from, undoable: false),
    );
  });

  Future<OutlineEditOutcome> moveFolder(
    String folderPath,
    String targetFolderPath, {
    bool undoable = true,
  }) => _edit(() async {
    final from = p.dirname(folderPath);
    final newPath = await _service.moveFolder(folderPath, targetFolderPath);
    _rekeyFolderState(folderPath, newPath);
    _expanded.add(targetFolderPath);
    if (!undoable) return const OutlineEditOutcome.ok();
    return OutlineEditOutcome.done(
      message:
          'Moved "${p.basename(folderPath)}" to '
          '${_folderLabel(targetFolderPath)}.',
      undo: () => moveFolder(newPath, from, undoable: false),
    );
  });

  /// Promotes a chapter file's `[White]` course chapters to real chapter
  /// files. When the source held nothing else it is removed, so an active
  /// chapter follows the first new one rather than pointing at a gone file.
  Future<OutlineEditOutcome> splitChapter(String chapterPath) =>
      _edit(() async {
        final result = await _service.splitChapter(
          chapterPath,
          isWhite: _isWhite,
        );
        _openChapters.remove(chapterPath);
        _expanded.add(p.dirname(chapterPath));
        if (_isActive(chapterPath)) {
          final successor = result.sourceRemoved
              ? (result.createdPaths.isEmpty ? null : result.createdPaths.first)
              : chapterPath;
          _activeChapterPath = successor;
          onActiveChapterMoved?.call(successor);
        }
        return const OutlineEditOutcome.ok();
      });

  Future<OutlineEditOutcome> deleteChapter(String chapterPath) =>
      _edit(() async {
        await _service.deleteChapter(chapterPath);
        _openChapters.remove(chapterPath);
        if (_isActive(chapterPath)) {
          _activeChapterPath = null;
          onActiveChapterMoved?.call(null);
        }
        return const OutlineEditOutcome.ok();
      });

  Future<OutlineEditOutcome> deleteFolder(String folderPath) => _edit(() async {
    await _service.deleteFolder(folderPath);
    _expanded.removeWhere(
      (f) => p.equals(f, folderPath) || p.isWithin(folderPath, f),
    );
    _openChapters.removeWhere((c) => p.isWithin(folderPath, c));
    final active = _activeChapterPath;
    if (active != null && p.isWithin(folderPath, active)) {
      _activeChapterPath = null;
      onActiveChapterMoved?.call(null);
    }
    return const OutlineEditOutcome.ok();
  });

  Future<OutlineEditOutcome> moveLine({
    required String fromChapterPath,
    required int gameIndex,
    required String toChapterPath,
  }) => moveLines(
    fromChapterPath: fromChapterPath,
    gameIndexes: {gameIndex},
    toChapterPath: toChapterPath,
  );

  /// Moves the lines at [gameIndexes] into [toChapterPath] — before the line
  /// now at [toIndex], or at the end — or reorders them when it is the same
  /// chapter. Undo puts every line back at the index it had.
  Future<OutlineEditOutcome> moveLines({
    required String fromChapterPath,
    required Set<int> gameIndexes,
    required String toChapterPath,
    int? toIndex,
  }) => _edit(() async {
    final names = _lineNames(fromChapterPath, gameIndexes);
    final moved = await _moveLinesNoted(
      fromChapterPath: fromChapterPath,
      gameIndexes: gameIndexes,
      toChapterPath: toChapterPath,
      toIndex: toIndex,
    );
    if (moved == null) {
      throw const OutlineEditException('That line is no longer there.');
    }
    final sameFile = p.equals(fromChapterPath, toChapterPath);
    // Dropped back where it was: nothing to say, nothing to undo.
    if (sameFile && listEquals(moved.origin, moved.landed)) {
      return const OutlineEditOutcome.ok();
    }
    final what = names.length == 1
        ? '"${names.first}"'
        : '${moved.landed.length} lines';
    return OutlineEditOutcome.done(
      message: sameFile
          ? 'Reordered $what.'
          : 'Moved $what to "${p.basenameWithoutExtension(toChapterPath)}".',
      undo: () => _edit(() async {
        final back = await _service.moveLines(
          fromChapterPath: toChapterPath,
          gameIndexes: moved.landed.toSet(),
          toChapterPath: fromChapterPath,
          toIndexes: moved.origin,
        );
        if (back.isEmpty) {
          throw const OutlineEditException('Those lines are no longer there.');
        }
        _openChapters.add(fromChapterPath);
        _noteChapterChanged(fromChapterPath);
        _noteChapterChanged(toChapterPath);
        return OutlineEditOutcome.done(
          message: sameFile ? 'Put $what back.' : 'Moved $what back.',
        );
      }),
    );
  });

  Future<OutlineEditOutcome> renameLine(
    String chapterPath,
    int gameIndex,
    String newName,
  ) => _edit(() async {
    if (newName.trim().isEmpty) {
      throw const OutlineEditException('Enter a name.');
    }
    final ok = await _service.renameLine(
      chapterPath,
      gameIndex,
      newName.trim(),
    );
    if (!ok) throw const OutlineEditException('That line is no longer there.');
    _noteChapterChanged(chapterPath);
    return const OutlineEditOutcome.ok();
  });

  Future<OutlineEditOutcome> deleteLine(String chapterPath, int gameIndex) =>
      deleteLines(chapterPath, {gameIndex});

  /// Deletes the lines at [gameIndexes]. Undo restores each at its index.
  Future<OutlineEditOutcome> deleteLines(
    String chapterPath,
    Set<int> gameIndexes,
  ) => _edit(() async {
    final names = _lineNames(chapterPath, gameIndexes);
    final removed = await _service.deleteLines(chapterPath, gameIndexes);
    if (removed.isEmpty) {
      throw const OutlineEditException('That line is no longer there.');
    }
    _noteChapterChanged(chapterPath);
    final what = names.length == 1
        ? '"${names.first}"'
        : '${removed.length} lines';
    return OutlineEditOutcome.done(
      message: 'Deleted $what.',
      undo: () => _edit(() async {
        await _service.restoreLines(chapterPath, removed);
        _openChapters.add(chapterPath);
        _noteChapterChanged(chapterPath);
        return OutlineEditOutcome.done(message: 'Restored $what.');
      }),
    );
  });

  /// [RepertoireOutlineService.moveLines] plus the bookkeeping every move
  /// shares: the indexes the lines came from (what undo needs), the
  /// destination unfolded, and the screen told when its file changed. Null
  /// when none of the lines existed.
  Future<({List<int> origin, List<int> landed})?> _moveLinesNoted({
    required String fromChapterPath,
    required Set<int> gameIndexes,
    required String toChapterPath,
    int? toIndex,
  }) async {
    final landed = await _service.moveLines(
      fromChapterPath: fromChapterPath,
      gameIndexes: gameIndexes,
      toChapterPath: toChapterPath,
      toIndex: toIndex,
    );
    if (landed.isEmpty) return null;
    _openChapters.add(toChapterPath);
    _noteChapterChanged(fromChapterPath);
    _noteChapterChanged(toChapterPath);
    return (origin: gameIndexes.toList()..sort(), landed: landed);
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  bool _isActive(String chapterPath) =>
      _activeChapterPath != null && p.equals(_activeChapterPath!, chapterPath);

  /// The active chapter's file changed under the screen; it must reload.
  void _noteChapterChanged(String chapterPath) {
    if (_isActive(chapterPath)) onActiveChapterMoved?.call(_activeChapterPath);
  }

  /// Names of the lines at [gameIndexes] as the outline last saw them, for
  /// a toast; an unknown line is named by its number.
  List<String> _lineNames(String chapterPath, Set<int> gameIndexes) {
    final lines = _outline?.findChapter(chapterPath)?.lines;
    return [
      for (final i in gameIndexes.toList()..sort())
        lines != null && i >= 0 && i < lines.length
            ? lines[i].name
            : 'line ${i + 1}',
    ];
  }

  /// How a toast names a folder: "top level" for the repertoire itself.
  String _folderLabel(String folderPath) =>
      _rootPath != null && p.equals(folderPath, _rootPath!)
      ? 'the top level'
      : '"${p.basename(folderPath)}"';

  void _followActive(String oldPath, String newPath) {
    if (_isActive(oldPath) && !p.equals(oldPath, newPath)) {
      _activeChapterPath = newPath;
      onActiveChapterMoved?.call(newPath);
    }
  }

  void _rekeyFolderState(String oldFolder, String newFolder) {
    String rekey(String path) => p.equals(path, oldFolder)
        ? newFolder
        : p.isWithin(oldFolder, path)
        ? p.join(newFolder, p.relative(path, from: oldFolder))
        : path;
    final e = _expanded.map(rekey).toList();
    _expanded
      ..clear()
      ..addAll(e);
    final o = _openChapters.map(rekey).toList();
    _openChapters
      ..clear()
      ..addAll(o);
    final active = _activeChapterPath;
    if (active != null && p.isWithin(oldFolder, active)) {
      _activeChapterPath = rekey(active);
      onActiveChapterMoved?.call(_activeChapterPath);
    }
  }
}
