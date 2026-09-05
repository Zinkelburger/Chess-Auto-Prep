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
import 'package:path/path.dart' as p;

import '../models/move_tree.dart';
import 'move_navigation.dart';
import '../models/repertoire_metadata.dart';
import '../models/study_document.dart';
import '../services/pgn_parsing_service.dart'
    show splitPgnIntoGames, extractHeaders, stripBom;
import '../services/storage/storage_factory.dart';
import '../services/storage/study_naming.dart';
import '../utils/atomic_file.dart';
import '../utils/chess_utils.dart' show tryParseFen;
import 'package:chess_auto_prep/utils/log.dart';
import 'package:chess_auto_prep/utils/safe_change_notifier.dart';

class StudyController extends ChangeNotifier
    with SafeChangeNotifier, MoveNavigation {
  StudyDocument _doc = StudyDocument.fresh('Untitled study');
  StudyDocument get doc => _doc;

  int _chapterIndex = 0;
  int get chapterIndex => _chapterIndex;
  StudyChapter get chapter => _doc.chapters[_chapterIndex];
  @override
  MoveTree get tree => chapter.tree;

  TreePath _path = TreePath.empty;

  @override
  TreePath get path => _path;

  bool _dirty = false;
  int _editRevision = 0;
  Future<bool> _saveTail = Future.value(true);
  bool get dirty => _dirty;

  bool flipped = false;

  /// Bumped whenever the active document is (re)assigned — [openStudy],
  /// [newStudy], [deleteStudy].  [openStudy] decodes off the UI isolate, so
  /// two quick opens can finish out of call order; the winner captures this
  /// token before its await and bails if a newer open/replace superseded it.
  int _docGeneration = 0;

  /// Exact content last read from or written to the active study. Autosaves
  /// compare against it so an external edit is never silently overwritten.
  String? _persistedContent;

  String? saveError;

  Timer? _autoSaveTimer;
  static const _autoSaveDelay = Duration(seconds: 2);

  /// Studies on disk (refreshed by [refreshStudyList]).
  List<RepertoireMetadata> availableStudies = [];

  /// Board position at the cursor.
  Position get currentPosition =>
      tryParseFen(tree.fenAt(_path)) ?? Chess.initial;

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
    if (!await flushSave()) return;
    final fresh = StudyDocument.fresh(name)..filePath = path;
    final content = fresh.toPgn();
    await storage.writeFile(path, content, createOnly: true);
    _doc = fresh;
    _persistedContent = content;
    saveError = null;
    _chapterIndex = 0;
    _path = TreePath.empty;
    _dirty = false;
    await refreshStudyList();
  }

  /// Write [pgn] out as a brand-new study named [name] (one chapter per game)
  /// and open it.  Returns the file path.
  ///
  /// The study file format *is* multi-game PGN, so the download goes straight
  /// to disk — no parse/re-serialise round trip that could drop an annotation
  /// on the way in.  [name] is sanitised and, if taken, suffixed.
  Future<String> createStudyFromPgn(String name, String pgn) async {
    _docGeneration++; // supersede any in-flight openStudy
    if (!await flushSave()) throw StateError(saveError ?? 'Study not saved');
    final reserved = await reserveStudyPath(name);
    await StorageFactory.instance.writeFile(
      reserved.path,
      '${pgn.trim()}\n',
      createOnly: true,
    );
    await refreshStudyList();
    await openStudy(reserved.path);
    return reserved.path;
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
      if (!await flushSave()) throw StateError(saveError ?? 'Study not saved');
    } else {
      final storage = StorageFactory.instance;
      final existed = await storage.fileExists(path);
      final existing = existed ? (await storage.readFile(path) ?? '') : '';
      final content = existing.trimRight().isEmpty
          ? chapter.toPgn()
          : '${existing.trimRight()}\n\n${chapter.toPgn()}';
      await storage.writeFile(
        path,
        content,
        createOnly: !existed,
        expectedContent: existed ? existing : null,
      );
    }
    await refreshStudyList();
  }

  Future<void> openStudy(String path) async {
    final generation = ++_docGeneration;
    if (!await flushSave()) return;
    final content = await StorageFactory.instance.readFile(path);
    if (generation != _docGeneration) return; // superseded by a newer open
    final name = p.basenameWithoutExtension(path);
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
    _persistedContent = content;
    saveError = null;
    _chapterIndex = 0;
    _path = TreePath.empty;
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
    if (!await flushSave()) return;
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
      _persistedContent = null;
      saveError = null;
      _chapterIndex = 0;
      _path = TreePath.empty;
      _dirty = false;
    }
    await refreshStudyList();
  }

  /// Whole-file atomic rewrite (storage layer writes tmp + rename).
  Future<bool> _save() {
    final next = _saveTail.then((_) => _saveCurrent());
    _saveTail = next;
    return next;
  }

  Future<bool> _saveCurrent() async {
    final document = _doc;
    final revision = _editRevision;
    final path = document.filePath;
    if (path == null) return !_dirty;
    try {
      final content = document.toPgn();
      await StorageFactory.instance.writeFile(
        path,
        content,
        createOnly: _persistedContent == null,
        expectedContent: _persistedContent,
      );
      if (!identical(_doc, document)) return true;
      _persistedContent = content;
      _dirty = _editRevision != revision;
      saveError = null;
      notifyListeners();
      return true;
    } on AtomicWriteConflict {
      saveError =
          'Study not saved because its file changed on disk. The newer disk '
          'copy was preserved.';
      notifyListeners();
    } catch (e) {
      saveError =
          'Could not save the study. Your unsaved edits are still open.';
      log.e('Error saving study: $e');
      notifyListeners();
    }
    try {
      final recovery =
          'recovery/study-${DateTime.now().microsecondsSinceEpoch}.pgn';
      await StorageFactory.instance.writeFile(
        recovery,
        document.toPgn(),
        createOnly: true,
      );
      saveError = '$saveError A recovery copy was saved to $recovery.';
    } catch (_) {
      // The open document remains dirty when even a recovery write fails.
    }
    notifyListeners();
    return false;
  }

  /// Persist any pending changes now (mode switch, dispose, file switch).
  Future<bool> flushSave() async {
    _autoSaveTimer?.cancel();
    await _saveTail;
    while (_dirty) {
      if (!await _save()) return false;
    }
    return true;
  }

  void _markDirty() {
    _editRevision++;
    _dirty = true;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(_autoSaveDelay, () => unawaited(_save()));
    notifyListeners();
  }

  // ── Chapters ─────────────────────────────────────────────────────────

  void selectChapter(int index) {
    if (index < 0 || index >= _doc.chapters.length) return;
    _chapterIndex = index;
    _path = TreePath.empty;
    notifyListeners();
  }

  /// Move the chapter at [oldIndex] to [newIndex].
  ///
  /// Indices are final positions in the reordered list (a
  /// [ReorderableListView] callback must subtract one when dragging down).
  /// The chapter being *viewed* stays selected, whether or not it moved.
  void reorderChapter(int oldIndex, int newIndex) {
    final chapters = _doc.chapters;
    if (oldIndex < 0 || oldIndex >= chapters.length) return;
    final target = newIndex.clamp(0, chapters.length - 1);
    if (oldIndex == target) return;
    final active = chapters[_chapterIndex];
    chapters.insert(target, chapters.removeAt(oldIndex));
    _chapterIndex = chapters.indexOf(active);
    _markDirty();
  }

  void addChapter(String name, {String? startingFen}) {
    _doc.chapters.add(StudyChapter(name: name, startingFen: startingFen));
    _chapterIndex = _doc.chapters.length - 1;
    _path = TreePath.empty;
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
      _path = TreePath.empty;
      _markDirty();
      if (!await flushSave()) throw StateError(saveError ?? 'Study not saved');
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
    _path = TreePath.empty;
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
    _path = TreePath.empty;
    _markDirty();
  }

  // ── Navigation ───────────────────────────────────────────────────────

  /// Jump the cursor to [target].  All navigation funnels here.
  /// (goBack / goForward / goToStart / goToEnd come from [MoveNavigation].)
  @override
  void jump(TreePath target) {
    if (!tree.isValidPath(target)) return;
    _path = target;
    notifyListeners();
  }

  void toggleFlipped() {
    flipped = !flipped;
    notifyListeners();
  }

  /// Park the cursor at the deepest node reachable by replaying [sanLine]
  /// from the root — how an [EditStudy] handoff's "View line" target lands
  /// on the position it advertised.
  void jumpToSanLine(List<String> sanLine) {
    _reanchorCursor(sanLine);
    notifyListeners();
  }

  // ── Editing ──────────────────────────────────────────────────────────

  /// Play [san] at the cursor: follows an existing child or adds a new node
  /// (a variation when the move differs from the mainline continuation).
  bool playSan(String san) {
    final path = tree.addMove(_path, san);
    if (path == null) return false;
    _path = path;
    _markDirty();
    return true;
  }

  void setComment(TreePath path, String? comment) {
    tree.setComment(path, comment);
    _markDirty();
  }

  /// Comment stored on the node at the cursor, annotation tokens and all.
  ///
  /// Board shapes (`[%cal]`/`[%csl]` arrows and circles) live in here, so the
  /// study screen reads and rewrites this rather than keeping shapes in a
  /// parallel structure that a PGN round-trip would drop.
  String? get cursorComment => tree.nodeAt(_path)?.comment;

  /// Whether the cursor is on a move (the root has no node to annotate).
  bool get cursorHasNode => _path.isNotEmpty && tree.nodeAt(_path) != null;

  void toggleNag(TreePath path, int nagId) {
    tree.toggleNag(path, nagId);
    _markDirty();
  }

  void deleteAt(TreePath path) {
    tree.deleteAt(path);
    // If the cursor was inside the deleted subtree, retreat to its parent.
    if (path.isAncestorOf(_path) || !tree.isValidPath(_path)) {
      _path = path.parent;
    }
    _markDirty();
  }

  void promote(TreePath path) {
    final onCursorLine = path.isAncestorOf(_path);
    final sanLine = tree.sanSequenceAt(_path);
    tree.promoteVariation(path);
    if (onCursorLine) _reanchorCursor(sanLine);
    _markDirty();
  }

  /// Recursively promote so [target] lies on the mainline (same algorithm as
  /// RepertoireController.makeMainLine).
  void makeMainLine(TreePath target) {
    if (target.isEmpty) return;
    final sanLine = tree.sanSequenceAt(_path);
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
    _path = path;
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
