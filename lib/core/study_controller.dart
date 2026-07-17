/// State owner for Study mode: a [StudyDocument] (chapters of editable
/// [MoveTree]s), the active chapter, a [TreePath] cursor, and debounced
/// autosave to the backing PGN file.
///
/// Modeled on [RepertoireController] but intentionally lighter: no colors,
/// no lines/coverage/traps — just annotated games in named files.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../models/move_tree.dart';
import '../models/repertoire_metadata.dart';
import '../models/study_document.dart';
import '../services/pgn_parsing_service.dart'
    show splitPgnIntoGames, extractHeaders, stripBom;
import '../services/storage/storage_factory.dart';
import '../utils/chess_utils.dart' show tryParseFen;
import 'package:chess_auto_prep/utils/log.dart';
import 'package:chess_auto_prep/utils/safe_change_notifier.dart';

class StudyController extends ChangeNotifier with SafeChangeNotifier {
  StudyDocument _doc = StudyDocument.fresh('Untitled study');
  StudyDocument get doc => _doc;

  int _chapterIndex = 0;
  int get chapterIndex => _chapterIndex;
  StudyChapter get chapter => _doc.chapters[_chapterIndex];
  MoveTree get tree => chapter.tree;

  TreePath _cursor = TreePath.empty;
  TreePath get cursor => _cursor;

  bool _dirty = false;
  bool get dirty => _dirty;

  bool flipped = false;

  /// Bumped whenever the active document is (re)assigned — [openStudy],
  /// [newStudy], [deleteStudy].  [openStudy] decodes off the UI isolate, so
  /// two quick opens can finish out of call order; the winner captures this
  /// token before its await and bails if a newer open/replace superseded it.
  int _docGeneration = 0;

  Timer? _autoSaveTimer;
  static const _autoSaveDelay = Duration(seconds: 2);

  /// Studies on disk (refreshed by [refreshStudyList]).
  List<RepertoireMetadata> availableStudies = [];

  /// Board position at the cursor.
  Position get currentPosition =>
      tryParseFen(tree.fenAt(_cursor)) ?? Chess.initial;

  // ── File management ──────────────────────────────────────────────────

  Future<void> refreshStudyList() async {
    availableStudies = await StorageFactory.instance.listStudyFiles();
    notifyListeners();
  }

  /// Create a new study file named [name] and make it active.
  /// Throws [ArgumentError] when the name is taken.
  Future<void> newStudy(String name) async {
    final storage = StorageFactory.instance;
    final path = await storage.studyFilePath(name);
    if (await storage.fileExists(path)) {
      throw ArgumentError('A study named "$name" already exists');
    }
    _docGeneration++; // supersede any in-flight openStudy
    await flushSave();
    _doc = StudyDocument.fresh(name)..filePath = path;
    _chapterIndex = 0;
    _cursor = TreePath.empty;
    _dirty = true; // persist the empty skeleton
    await flushSave();
    await refreshStudyList();
  }

  /// Append a chapter (parsed from [pgn], including any `[FEN]` header) to
  /// the study at [path], creating the file when it doesn't exist yet.
  ///
  /// Routes through the in-memory document when that study is the open one,
  /// so a later autosave can't clobber the addition; otherwise edits the
  /// file on disk directly.
  Future<void> addChapterToStudyFile(
    String path,
    String chapterName,
    String pgn,
  ) async {
    // Carry the source headers along (StarRating, White/Black, …) so a
    // chapter written by the puzzle creator or "Add line to study" keeps
    // them across the in-memory round-trip (Event/FEN/SetUp are regenerated
    // by StudyChapter.toPgn).
    final chapter = StudyChapter(
      name: chapterName,
      headers: extractHeaders(pgn),
      tree: MoveTree.fromPgn(pgn),
    );
    if (_doc.filePath == path) {
      _doc.chapters.add(chapter);
      _markDirty();
      await flushSave();
    } else {
      final storage = StorageFactory.instance;
      final existing = await storage.fileExists(path)
          ? (await storage.readFile(path) ?? '')
          : '';
      final content = existing.trimRight().isEmpty
          ? chapter.toPgn()
          : '${existing.trimRight()}\n\n${chapter.toPgn()}';
      await storage.writeFile(path, content);
    }
    await refreshStudyList();
  }

  Future<void> openStudy(String path) async {
    final generation = ++_docGeneration;
    await flushSave();
    final content = await StorageFactory.instance.readFile(path);
    if (generation != _docGeneration) return; // superseded by a newer open
    final name = path.split('/').last.replaceAll(RegExp(r'\.pgn$'), '');
    // fromPgn runs PgnGame.parsePgn + a full move replay for every chapter —
    // off the UI isolate so opening a large study doesn't freeze the frame.
    final text = content ?? '';
    final loaded = await Isolate.run(
      () => StudyDocument.fromPgn(text, name: name, filePath: path),
    );
    // A later open (or newStudy/deleteStudy) may have finished while this
    // decode ran; don't clobber it with this now-stale document.
    if (generation != _docGeneration) return;
    // Trees crossing the isolate boundary carry foreign node ids — adopt
    // them only after re-minting via [MoveTree.copyWithFreshIds].
    _doc = StudyDocument(
      name: loaded.name,
      filePath: loaded.filePath,
      chapters: [
        for (final c in loaded.chapters)
          StudyChapter(
            name: c.name,
            headers: c.headers,
            tree: c.tree.copyWithFreshIds(),
          ),
      ],
    );
    _chapterIndex = 0;
    _cursor = TreePath.empty;
    _dirty = false;
    notifyListeners();
  }

  /// Rename the current study — moves its file to `<newName>.pgn`.  Only
  /// studies inside the studies directory can be renamed (an external file
  /// opened via "Edit set in Study" keeps its own name; rename the set in
  /// Tactics mode instead).  Throws [ArgumentError] when the name is taken.
  Future<void> renameStudy(String newName) async {
    final oldPath = _doc.filePath;
    if (oldPath == null) return;
    if (!availableStudies.any((s) => s.filePath == oldPath)) return;
    final storage = StorageFactory.instance;
    final newPath = await storage.studyFilePath(newName);
    if (newPath == oldPath) return;
    if (await storage.fileExists(newPath)) {
      throw ArgumentError('A study named "$newName" already exists');
    }
    await flushSave();
    await storage.renameFile(oldPath, newPath);
    _doc.filePath = newPath;
    _doc.name = newName;
    await refreshStudyList();
  }

  Future<void> deleteStudy(String path) async {
    await StorageFactory.instance.deleteFile(path);
    if (_doc.filePath == path) {
      _docGeneration++; // supersede any in-flight openStudy of this file
      _doc = StudyDocument.fresh('Untitled study');
      _chapterIndex = 0;
      _cursor = TreePath.empty;
      _dirty = false;
    }
    await refreshStudyList();
  }

  /// Whole-file atomic rewrite (storage layer writes tmp + rename).
  Future<void> _save() async {
    final path = _doc.filePath;
    if (path == null) return;
    try {
      await StorageFactory.instance.writeFile(path, _doc.toPgn());
      _dirty = false;
    } catch (e) {
      log.e('Error saving study: $e');
    }
  }

  /// Persist any pending changes now (mode switch, dispose, file switch).
  Future<void> flushSave() async {
    _autoSaveTimer?.cancel();
    if (_dirty) await _save();
  }

  void _markDirty() {
    _dirty = true;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(_autoSaveDelay, _save);
    notifyListeners();
  }

  // ── Chapters ─────────────────────────────────────────────────────────

  void selectChapter(int index) {
    if (index < 0 || index >= _doc.chapters.length) return;
    _chapterIndex = index;
    _cursor = TreePath.empty;
    notifyListeners();
  }

  void addChapter(String name, {String? startingFen}) {
    _doc.chapters.add(StudyChapter(name: name, startingFen: startingFen));
    _chapterIndex = _doc.chapters.length - 1;
    _cursor = TreePath.empty;
    _markDirty();
  }

  /// Append every game in [pgn] as a new chapter (Lichess-style PGN import).
  /// Each game's `[Event]` becomes the chapter name; `[FEN]` starting
  /// positions and comments are preserved. Returns the number of chapters
  /// added (0 when [pgn] holds no parseable games), selecting the first new
  /// chapter and persisting immediately.
  Future<int> importChapters(String pgn) async {
    // Off-isolate for the same reason as [openStudy]; ids re-minted on adopt.
    final games = await compute(_parseChapterTreesEntry, pgn);
    final firstNewIndex = _doc.chapters.length;
    int added = 0;
    for (final (headers, tree) in games) {
      // Skip fragments that are neither a game nor a headered stub.
      if (tree.isEmpty && headers.isEmpty) continue;
      final name = headers['Event']?.trim().isNotEmpty == true
          ? headers['Event']!
          : 'Chapter ${_doc.chapters.length + 1}';
      _doc.chapters.add(
        StudyChapter(
          name: name,
          headers: headers,
          tree: tree.copyWithFreshIds(),
        ),
      );
      added++;
    }
    if (added > 0) {
      _chapterIndex = firstNewIndex;
      _cursor = TreePath.empty;
      _markDirty();
      await flushSave();
    }
    return added;
  }

  void renameChapter(int index, String name) {
    if (index < 0 || index >= _doc.chapters.length) return;
    _doc.chapters[index].name = name;
    _markDirty();
  }

  /// Replace the current chapter's starting position with [fen]. The
  /// chapter's moves are cleared — they were rooted in the old position.
  void setChapterStartingPosition(String fen) {
    final old = chapter;
    _doc.chapters[_chapterIndex] = StudyChapter(
      name: old.name,
      headers: Map<String, String>.from(old.headers),
      startingFen: fen,
    );
    _cursor = TreePath.empty;
    _markDirty();
  }

  /// Whether the current chapter has any moves (something to train).
  bool get chapterHasMoves => tree.roots.isNotEmpty;

  void deleteChapter(int index) {
    if (_doc.chapters.length <= 1) return; // keep at least one
    if (index < 0 || index >= _doc.chapters.length) return;
    _doc.chapters.removeAt(index);
    if (_chapterIndex >= _doc.chapters.length) {
      _chapterIndex = _doc.chapters.length - 1;
    }
    _cursor = TreePath.empty;
    _markDirty();
  }

  // ── Navigation ───────────────────────────────────────────────────────

  void jumpTo(TreePath path) {
    if (!tree.isValidPath(path)) return;
    _cursor = path;
    notifyListeners();
  }

  void goBack() {
    if (_cursor.isEmpty) return;
    _cursor = _cursor.parent;
    notifyListeners();
  }

  /// Follow the mainline continuation from the cursor, if any.
  void goForward() {
    final children = _cursor.isEmpty
        ? tree.roots
        : (tree.nodeAt(_cursor)?.children ?? []);
    if (children.isEmpty) return;
    _cursor = _cursor.child(0);
    notifyListeners();
  }

  void goToStart() {
    _cursor = TreePath.empty;
    notifyListeners();
  }

  void goToEnd() {
    _cursor = tree.mainlineEndFrom(_cursor);
    notifyListeners();
  }

  void toggleFlipped() {
    flipped = !flipped;
    notifyListeners();
  }

  // ── Editing ──────────────────────────────────────────────────────────

  /// Play [san] at the cursor: follows an existing child or adds a new node
  /// (a variation when the move differs from the mainline continuation).
  bool playSan(String san) {
    final path = tree.addMove(_cursor, san);
    if (path == null) return false;
    _cursor = path;
    _markDirty();
    return true;
  }

  void setComment(TreePath path, String? comment) {
    tree.setComment(path, comment);
    _markDirty();
  }

  void toggleNag(TreePath path, int nagId) {
    tree.toggleNag(path, nagId);
    _markDirty();
  }

  void deleteAt(TreePath path) {
    tree.deleteAt(path);
    // If the cursor was inside the deleted subtree, retreat to its parent.
    if (path.isAncestorOf(_cursor) || !tree.isValidPath(_cursor)) {
      _cursor = path.parent;
    }
    _markDirty();
  }

  void promote(TreePath path) {
    final onCursorLine = path.isAncestorOf(_cursor);
    final sanLine = tree.sanSequenceAt(_cursor);
    tree.promoteVariation(path);
    if (onCursorLine) _reanchorCursor(sanLine);
    _markDirty();
  }

  /// Recursively promote so [target] lies on the mainline (same algorithm as
  /// RepertoireController.makeMainLine).
  void makeMainLine(TreePath target) {
    if (target.isEmpty) return;
    final sanLine = tree.sanSequenceAt(_cursor);
    final indices = target.toList();
    for (int depth = 0; depth < indices.length; depth++) {
      if (indices[depth] != 0) {
        tree.promoteVariation(TreePath(indices.sublist(0, depth + 1)));
        indices[depth] = 0;
      }
    }
    _reanchorCursor(sanLine);
    _markDirty();
  }

  /// After a structural change, re-locate the cursor by replaying its SAN
  /// sequence (paths shift when siblings reorder).
  void _reanchorCursor(List<String> sanLine) {
    var path = TreePath.empty;
    var siblings = tree.roots;
    for (final san in sanLine) {
      final idx = siblings.indexWhere((n) => n.san == san);
      if (idx == -1) break;
      path = path.child(idx);
      siblings = siblings[idx].children;
    }
    _cursor = path;
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    // Best-effort synchronous kick; the atomic write completes on its own.
    if (_dirty) unawaited(_save());
    super.dispose();
  }
}

// ── compute() entry points ─────────────────────────────────────────────────
// PGN → MoveTree parsing replays every move with dartchess; big studies
// block long enough to freeze the UI, so the controller parses off-isolate.
// Trees crossing the isolate boundary carry foreign node ids — adopt them
// only via [MoveTree.copyWithFreshIds].

List<(Map<String, String>, MoveTree)> _parseChapterTreesEntry(String pgn) {
  final games = splitPgnIntoGames(stripBom(pgn));
  return [
    for (final gameText in games)
      (extractHeaders(gameText), MoveTree.fromPgn(gameText)),
  ];
}
