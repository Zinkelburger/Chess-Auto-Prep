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

import '../../../models/move_tree.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import '../../../chess_core/moves/move_navigation.dart';
import '../../repertoires/models/repertoire_metadata.dart';
import '../models/study_document.dart';
import '../models/study_projection.dart';
import '../../../chess_core/moves/move_tree_snapshot.dart';
import 'study_projection_cache.dart';
import '../models/study_workspace_snapshot.dart';
import '../../../chess_core/pgn/pgn_text.dart'
    show splitPgnIntoGames, extractHeaders, stripBom, countPgnGames;
import '../repositories/study_library_repository.dart';
import '../../documents/repositories/pgn_document_store.dart';
import '../../documents/repositories/document_save_actions.dart';
import '../../documents/controllers/document_save_session.dart';
import '../../documents/models/document_save_state.dart';
import '../../documents/models/pgn_document.dart';
import '../../../utils/chess_utils.dart' show tryParseFen;
import '../../../utils/safe_change_notifier.dart';

class StudyController extends ChangeNotifier
    with SafeChangeNotifier, MoveNavigation
    implements DocumentSaveActions {
  StudyController({
    required this._library,
    required this._documents,
    this._autoSaveDelay = const Duration(seconds: 2),
    Future<StudyDocument> Function(String, String, String)? decode,
  }) : _decode = decode ?? _decodeStudy {
    _attachSession(
      DocumentSaveSession.draft(_documents, path: '', content: _doc.toPgn()),
    );
  }
  final StudyLibraryRepository _library;
  final PgnDocumentStore _documents;
  final Duration _autoSaveDelay;
  final Future<StudyDocument> Function(String, String, String) _decode;
  late DocumentSaveSession _session;
  StreamSubscription<DocumentSaveState>? _sessionSubscription;
  final _saveChanges = StreamController<DocumentSaveState>.broadcast(
    sync: true,
  );
  bool _reloading = false;
  bool _autoSaveBlocked = false;
  bool _relocating = false;
  bool _adopting = false;
  PgnOpenResult? _reloadFailure;
  String? _recoveryPath;
  @override
  Stream<DocumentSaveState> get changes => _saveChanges.stream;
  @override
  DocumentSaveState get state {
    final saved = _session.state;
    final normal = saved.outcome == null;
    return DocumentSaveState(
      path: saved.path,
      content: saved.content,
      baseline: saved.baseline,
      pendingEdits: _dirty,
      phase: _reloading || _relocating
          ? DocumentSavePhase.reloading
          : _dirty && normal && !saved.busy
          ? DocumentSavePhase.dirty
          : saved.phase,
      outcome: saved.outcome,
      uncertainPath: saved.uncertainPath,
      readFailure: _reloadFailure ?? saved.readFailure,
      retainedDrafts: saved.retainedDrafts,
    );
  }

  bool get replacingDocument => _reloading;
  @override
  void notifyListeners() {
    if (isDisposed || _adopting) return;
    _saveChanges.add(state);
    super.notifyListeners();
  }

  void _attachSession(DocumentSaveSession session) {
    unawaited(_sessionSubscription?.cancel());
    _session = session;
    _sessionSubscription = session.changes.listen((_) => notifyListeners());
  }

  StudyDocument _doc = StudyDocument.fresh('Untitled study');
  final _projections = StudyProjectionCache();
  StudyDocumentProjection get doc => _projections.read(_doc, _editRevision);

  int _chapterIndex = 0;
  int get chapterIndex => _chapterIndex;
  StudyChapter get _chapter => _doc.chapters[_chapterIndex];
  MoveTree get _tree => _chapter.tree;
  StudyChapterProjection chapterAt(int index) =>
      _projections.readChapter(_doc, _doc.chapters[index]);
  StudyChapterProjection get chapter => chapterAt(_chapterIndex);
  int indexOfChapter(StudyChapterProjection snapshot) {
    if (_projections.sessionFor(_doc) != snapshot.session) return -1;
    final index = chapterList.chapters.indexWhere(
      (item) => item.key == snapshot.key,
    );
    return index >= 0 && chapterAt(index) == snapshot ? index : -1;
  }

  StudyChapterListProjection get chapterList =>
      _projections.readChapterList(_doc, _editRevision);
  StudyTitle get title => (
    session: _projections.sessionFor(_doc),
    name: _doc.name,
    filePath: _doc.filePath,
    canRename: _doc.filePath != null && _studyPaths.contains(_doc.filePath),
  );

  StudyCursorProjection? _cursor;
  Object? _cursorInputs;
  int _viewRevision = 0;
  StudyCursorProjection get cursor {
    final session = _projections.sessionFor(_doc);
    final key = _projections.chapterKey(_doc, _chapter);
    final inputs = (session, key, _tree.version, _path, _flipped);
    if (_cursor != null && _cursorInputs == inputs) return _cursor!;
    _cursorInputs = inputs;
    final position = _tree.positionAt(_path);
    final comment = _tree.commentAt(_path);
    final nags = _tree.nodeAt(_path)?.nags ?? const <int>[];
    final old = _cursor;
    if (old != null &&
        old.session == session &&
        old.chapterKey == key &&
        old.path == _path &&
        old.flipped == _flipped &&
        old.position.fen == position.fen &&
        old.comment == comment &&
        listEquals(old.nags, nags)) {
      return old;
    }
    return _cursor = StudyCursorProjection(
      session: session,
      chapterKey: key,
      revision: ++_viewRevision,
      path: _path,
      position: position,
      flipped: _flipped,
      comment: comment,
      nags: nags,
    );
  }

  @override
  MoveTreeSnapshot get tree => chapter.tree;

  TreePath _path = TreePath.empty;

  @override
  TreePath get path => _path;

  bool _dirty = false;
  int _editRevision = 0;
  Future<bool> _saveTail = Future.value(true);
  bool get dirty => _dirty;
  Object get navigationRevision =>
      (_docGeneration, _editRevision, _chapterIndex);

  /// Cheap equality for an approval to close; no whole-tree serialization.
  Object get closeRevision => (
    _docGeneration,
    _editRevision,
    _saveTail,
    _session.state.baseline,
    _session.state.outcome,
    _session.state.retainedDrafts,
  );
  bool get autoSaveEnabled => !_autoSaveBlocked && _doc.filePath != null;

  /// Whether the board shows Black at the bottom.  Follows the chapter's
  /// [StudyChapter.orientation] whenever a chapter opens; "Flip board" turns
  /// it for this sitting only, "Edit chapter" changes what is saved.
  bool get flipped => _flipped;
  bool _flipped = false;

  void _faceChapterOrientation() {
    if (_doc.chapters.isEmpty) return;
    _flipped = _chapter.orientation == Side.black;
  }

  /// Bumped whenever the active document is (re)assigned — [openStudy],
  /// [newStudy], [deleteStudy].  [openStudy] decodes off the UI isolate, so
  /// two quick opens can finish out of call order; the winner captures this
  /// token before its await and bails if a newer open/replace superseded it.
  int _docGeneration = 0;

  String? get saveError {
    final outcome = _session.state.outcome;
    final message = switch (outcome) {
      PgnConflict() =>
        'Study not saved because its file changed on disk. The newer disk copy was preserved.',
      PgnNameCollision() =>
        'A file already exists at that destination. Your draft is still open.',
      PgnWriteUncertain() =>
        'The study save could not be confirmed. Inspect or reload before saving again.',
      PgnWriteFailed() =>
        'Could not save the study. Your unsaved edits are still open.',
      _ =>
        _reloadFailure == null
            ? null
            : 'Could not reload the study. Your current edits are still open.',
    };
    if (message == null) return null;
    return _recoveryPath == null
        ? message
        : '$message A recovery copy was saved to $_recoveryPath.';
  }

  Timer? _autoSaveTimer;

  /// Studies on disk (refreshed by [refreshStudyList]).
  List<RepertoireMetadata> _availableStudies = const [];
  Set<String> _studyPaths = const {};
  List<RepertoireMetadata> get availableStudies => _availableStudies;

  /// Board position at the cursor.
  Position get currentPosition =>
      tryParseFen(_tree.fenAt(_path)) ?? Chess.initial;

  // ── File management ──────────────────────────────────────────────────

  Future<void> refreshStudyList() async {
    final studies = await _library.list();
    if (isDisposed) return;
    _availableStudies = List.unmodifiable(studies);
    _studyPaths = {for (final study in studies) study.filePath};
    notifyListeners();
  }

  /// Called only at bounded checkpoint/save boundaries, not for every repaint.
  StudyWorkspaceSnapshot captureWorkspace() => StudyWorkspaceSnapshot(
    name: _doc.name,
    path: _doc.filePath ?? '',
    content: _doc.toPgn(),
    dirty: _dirty,
    baseline: _session.state.baseline,
    uncertain:
        state.uncertain || _session.state.phase == DocumentSavePhase.saving,
    uncertainPath: _session.state.uncertainPath,
    retainedDrafts: _session.state.retainedDrafts,
    chapter: _chapterIndex,
    cursor: _path.toList(),
    flipped: _flipped,
  );

  /// Restoring is a read-only editor operation. Preserve displaced work and the
  /// original commit baseline; an explicit save must still validate that baseline.
  Future<void> restoreWorkspace(StudyWorkspaceSnapshot snapshot) async {
    if (isDisposed || _reloading || _relocating) {
      throw StateError('Study is busy');
    }
    _reloading = true;
    _autoSaveTimer?.cancel();
    final generation = _docGeneration;
    final revision = _editRevision;
    notifyListeners();
    try {
      await _saveTail;
      final loaded = await _decode(
        snapshot.content,
        snapshot.name,
        snapshot.path,
      );
      if (isDisposed ||
          generation != _docGeneration ||
          revision != _editRevision) {
        throw StateError('Study changed while recovering');
      }
      final retained = [
        ...snapshot.retainedDrafts,
        ..._session.state.retainedDrafts,
      ];
      if (_dirty) {
        retained.add(
          RetainedDocumentDraft(
            path: _doc.filePath ?? '',
            content: _doc.toPgn(),
            baseline: _session.state.baseline,
          ),
        );
      }
      _adopting = true;
      unawaited(_session.dispose());
      _attachSession(
        DocumentSaveSession.recovered(
          _documents,
          path: snapshot.path,
          content: snapshot.content,
          baseline: snapshot.baseline,
          uncertain: snapshot.uncertain,
          uncertainPath: snapshot.uncertainPath,
          retainedDrafts: retained,
        ),
      );
      loaded.filePath = snapshot.path.isEmpty ? null : snapshot.path;
      _installReloaded(_freshIds(loaded), dirty: snapshot.dirty);
      _autoSaveBlocked = true;
      _chapterIndex = snapshot.chapter.clamp(0, _doc.chapters.length - 1);
      final cursor = TreePath.from(snapshot.cursor);
      _path = _tree.isValidPath(cursor) ? cursor : TreePath.empty;
      _flipped = snapshot.flipped;
    } finally {
      _adopting = false;
      _reloading = false;
      notifyListeners();
    }
  }

  /// Create a new study file named [name] and make it active.
  /// Throws [ArgumentError] when the name is taken.
  Future<void> newStudy(String name) async {
    if (_reloading || _relocating || isDisposed) return;
    final path = await _library.pathForName(name);
    if (await _library.exists(path)) {
      throw ArgumentError('A study named "$name" already exists');
    }
    final generation = ++_docGeneration;
    if (!await flushSave()) return;
    final fresh = StudyDocument.fresh(name)..filePath = path;
    final result = await _documents.create(path, fresh.toPgn());
    if (result is! PgnSaved) throw StudyWriteException(result);
    if (isDisposed || generation != _docGeneration) return;
    if (!await flushSave() ||
        isDisposed ||
        generation != _docGeneration ||
        _dirty) {
      return;
    }
    _adoptDocument(fresh, snapshot: result.after);
    await refreshStudyList();
  }

  /// Make [doc] the active study, its cursor at the first chapter's start.
  /// [snapshot] is the captured disk revision (null for a study that has
  /// never been written), so the next autosave can detect an external edit.
  void _adoptDocument(StudyDocument doc, {required PgnSnapshot? snapshot}) {
    unawaited(_session.dispose());
    _doc = doc;
    _attachSession(
      DocumentSaveSession.recovered(
        _documents,
        path: doc.filePath ?? '',
        content: snapshot?.content ?? doc.toPgn(),
        baseline: snapshot,
        retainedDrafts: _session.state.retainedDrafts,
      ),
    );
    _reloadFailure = null;
    _recoveryPath = null;
    _autoSaveBlocked = false;
    _chapterIndex = 0;
    _path = TreePath.empty;
    _faceChapterOrientation();
    _dirty = false;
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
    String pgn, {
    bool createOnly = false,
  }) async {
    await addChaptersToStudyFile(path, [
      StudyChapter.fromGameText(pgn, name: chapterName),
    ], createOnly: createOnly);
  }

  /// Append a selection in one write, preserving the open study's unsaved edits.
  /// Returns the first new chapter's index, even when chapter names repeat.
  Future<int> addChaptersToStudyFile(
    String path,
    List<StudyChapter> chapters, {
    bool createOnly = false,
  }) async {
    if (chapters.isEmpty) throw ArgumentError('Choose at least one game');
    final int firstIndex;
    if (_doc.filePath == path && !createOnly) {
      firstIndex = _doc.chapters.length;
      _doc.chapters.addAll([
        for (final chapter in chapters)
          StudyChapter(
            name: chapter.name,
            orientation: chapter.orientation,
            headers: chapter.headers,
            tree: chapter.tree.copyWithFreshIds(),
          ),
      ]);
      _markDirty();
      if (!await flushSave()) throw StateError(saveError ?? 'Study not saved');
    } else {
      final opened = createOnly
          ? const PgnMissing()
          : await _documents.open(path);
      if (opened is PgnReadFailed) throw opened.error;
      final existing = opened is PgnOpened ? opened.snapshot.content : '';
      firstIndex = countPgnGames(existing);
      final additions = chapters
          .map(
            (chapter) =>
                chapter.toPgn(studyName: p.basenameWithoutExtension(path)),
          )
          .join('\n\n');
      final content = existing.trimRight().isEmpty
          ? additions
          : '${existing.trimRight()}\n\n$additions';
      final result = opened is PgnOpened
          ? await _documents.save(opened.snapshot, content)
          : await _documents.create(path, content);
      if (result is! PgnSaved) throw StudyWriteException(result);
    }
    await refreshStudyList();
    return firstIndex;
  }

  Future<bool> openStudy(String path) async {
    if (_reloading || _relocating || isDisposed) return false;
    final generation = ++_docGeneration;
    if (!await flushSave()) return false;
    final opened = await _documents.open(path);
    if (generation != _docGeneration || isDisposed) return false;
    if (opened is! PgnOpened) throw StateError('Could not open study: $opened');
    final loaded = await _decode(
      opened.snapshot.content,
      p.basenameWithoutExtension(path),
      opened.snapshot.path,
    );
    if (generation != _docGeneration || isDisposed) return false;
    // Editing remains possible during read/decode. Persist those newer edits
    // before replacing their document, and stop if that save cannot be proved.
    if (!await flushSave() ||
        isDisposed ||
        generation != _docGeneration ||
        _dirty) {
      return false;
    }
    _adoptDocument(_freshIds(loaded), snapshot: opened.snapshot);
    notifyListeners();
    return true;
  }

  /// Rename the current study — moves its file to `<newName>.pgn`.  Only
  /// studies inside the studies directory can be renamed (an external file
  /// opened via "Edit set in Study" keeps its own name; rename the set in
  /// Tactics mode instead).  Throws [ArgumentError] when the name is taken.
  Future<void> renameStudy(String newName) async {
    if (_reloading || _relocating || isDisposed) return;
    final document = _doc;
    final oldPath = document.filePath;
    if (oldPath == null ||
        !availableStudies.any((s) => s.filePath == oldPath)) {
      return;
    }
    final generation = ++_docGeneration;
    final newPath = await _library.pathForName(newName);
    if (newPath == oldPath) return;
    if (await _library.exists(newPath)) {
      throw ArgumentError('A study named "$newName" already exists');
    }
    if (!await flushSave() ||
        generation != _docGeneration ||
        isDisposed ||
        _dirty) {
      return;
    }
    final baseline = _session.state.baseline;
    if (baseline == null) return;
    _relocating = true;
    _autoSaveTimer?.cancel();
    notifyListeners();
    try {
      final relocated = await _library.rename(baseline, newPath);
      _session.relocate(relocated);
      document.filePath = relocated.path;
      document.name = newName;
    } finally {
      _relocating = false;
      _scheduleAutoSave();
      notifyListeners();
    }
    await refreshStudyList();
  }

  Future<void> deleteStudy(String path) async {
    if (_reloading || _relocating || isDisposed) return;
    if (_doc.filePath != path) {
      await _library.delete(path);
      await refreshStudyList();
      return;
    }
    final document = _doc;
    final generation = ++_docGeneration;
    if (!await flushSave() ||
        generation != _docGeneration ||
        isDisposed ||
        _dirty) {
      return;
    }
    _relocating = true;
    _autoSaveTimer?.cancel();
    notifyListeners();
    try {
      await _library.delete(path);
      if (_dirty) {
        // Edits made after confirmation belong to an unsaved document; never
        // recreate the deleted path on a debounce or discard the newer draft.
        document.filePath = null;
        unawaited(_session.dispose());
        _attachSession(
          DocumentSaveSession.draft(
            _documents,
            path: '',
            content: document.toPgn(),
          ),
        );
      } else {
        _adoptDocument(StudyDocument.fresh('Untitled study'), snapshot: null);
      }
    } finally {
      _relocating = false;
      notifyListeners();
    }
    await refreshStudyList();
  }

  Future<String> copyDestination(String name) => _library.pathForName(name);

  /// An export has its own save owner and never changes the open study's path,
  /// revision or dirty state. The dialog owns the returned session's lifetime.
  DocumentSaveSession exportSession(String destination) =>
      DocumentSaveSession.draft(
        _documents,
        path: destination,
        content: _doc.toPgn(),
      );

  /// One chapter as a PGN game, tagged the way Lichess exports chapters.
  String chapterPgn(int index) =>
      _doc.chapters[index].toPgn(studyName: _doc.name);

  @override
  Future<PgnWriteResult?> save() => _write();

  @override
  Future<PgnWriteResult?> saveCopy(String destination) =>
      _write(copyTo: destination);

  Future<PgnWriteResult?> _write({
    String? copyTo,
    bool automatic = false,
  }) async {
    if (_reloading || _relocating || isDisposed) return null;
    final owner = _session;
    PgnWriteResult? result;
    final next = _saveTail.then((_) async {
      if (_reloading || _relocating || !identical(owner, _session)) {
        return false;
      }
      if (automatic && _autoSaveBlocked) return false;
      final document = _doc;
      final revision = _editRevision;
      if (copyTo == null && document.filePath == null) return !_dirty;
      _session.edit(document.toPgn());
      result = copyTo == null
          ? await _session.save()
          : await _session.saveCopy(copyTo);
      if (!identical(document, _doc)) return true;
      if (result is PgnSaved || result == null && !_session.state.dirty) {
        _dirty = _editRevision != revision;
        if (result is PgnSaved) {
          document.filePath = (result as PgnSaved).after.path;
          if (copyTo != null) {
            _docGeneration++;
            document.name = p.basenameWithoutExtension(document.filePath!);
          }
        }
        _recoveryPath = null;
        _reloadFailure = null;
        _autoSaveBlocked = false;
        _scheduleAutoSave();
        notifyListeners();
        return true;
      }
      // Never replay a failed/uncertain operation on the debounce timer.
      _autoSaveBlocked = true;
      _autoSaveTimer?.cancel();
      if (result != null) {
        try {
          _recoveryPath = await _library.retainRecovery(
            document.name,
            document.toPgn(),
          );
        } catch (_) {
          /* Recovery is best effort; the live draft remains authoritative. */
        }
      }
      notifyListeners();
      return false;
    });
    _saveTail = next;
    await next;
    if (copyTo != null && result is PgnSaved && !isDisposed) {
      await refreshStudyList();
    }
    return result;
  }

  Future<bool> flushSave() async {
    _autoSaveTimer?.cancel();
    if (_reloading || _relocating) return false;
    await _saveTail;
    if (_autoSaveBlocked || state.uncertain) return false;
    while (_dirty) {
      final result = await _write(automatic: true);
      if (result is! PgnSaved && _dirty) return false;
    }
    return !state.uncertain;
  }

  void _markDirty() {
    _projections.edited();
    _editRevision++;
    _dirty = true;
    _scheduleAutoSave();
    notifyListeners();
  }

  void _scheduleAutoSave() {
    _autoSaveTimer?.cancel();
    if (!isDisposed &&
        _dirty &&
        !_reloading &&
        !_relocating &&
        !_autoSaveBlocked &&
        _doc.filePath != null) {
      _autoSaveTimer = Timer(
        _autoSaveDelay,
        () => unawaited(_saveAutomatically()),
      );
    }
  }

  Future<void> _saveAutomatically() async {
    if (_autoSaveBlocked) return;
    await _write(automatic: true);
  }

  @override
  void keepEditing() {
    _session.keepEditing();
  }

  @override
  Future<PgnOpenResult> inspectCurrent() => _session.inspectCurrent();

  @override
  Future<void> reloadPreservingDraft() async {
    if (_reloading || _relocating || isDisposed) return;
    await _saveTail;
    if (_reloading || _relocating || isDisposed) return;
    final session = _session;
    final generation = _docGeneration;
    _reloading = true;
    _autoSaveTimer?.cancel();
    _reloadFailure = null;
    notifyListeners();
    try {
      final opened = await session.inspectCurrent();
      if (opened is! PgnOpened) {
        _reloadFailure = opened;
        return;
      }
      final snapshot = opened.snapshot;
      final loaded = await _decode(
        snapshot.content,
        p.basenameWithoutExtension(snapshot.path),
        snapshot.path,
      );
      if (isDisposed ||
          generation != _docGeneration ||
          !identical(session, _session)) {
        return;
      }
      _adopting = true;
      if (_dirty) session.edit(_doc.toPgn());
      session.adoptReload(snapshot);
      _installReloaded(_freshIds(loaded), dirty: false);
    } catch (error) {
      _reloadFailure = PgnReadFailed(error);
    } finally {
      _adopting = false;
      _reloading = false;
      notifyListeners();
    }
  }

  @override
  Future<void> restoreDraft(int index) async {
    if (_reloading || state.busy || isDisposed) return;
    final session = _session;
    final generation = _docGeneration;
    final draft = state.retainedDrafts[index];
    _reloading = true;
    _autoSaveTimer?.cancel();
    _reloadFailure = null;
    notifyListeners();
    try {
      final loaded = await _decode(
        draft.content,
        p.basenameWithoutExtension(state.path),
        state.path,
      );
      if (isDisposed ||
          generation != _docGeneration ||
          !identical(session, _session)) {
        return;
      }
      _adopting = true;
      if (_dirty) session.edit(_doc.toPgn());
      session.restoreCapturedDraft(index);
      _installReloaded(_freshIds(loaded), dirty: session.state.dirty);
    } catch (error) {
      _reloadFailure = PgnReadFailed(error);
    } finally {
      _adopting = false;
      _reloading = false;
      notifyListeners();
    }
  }

  void _installReloaded(StudyDocument doc, {required bool dirty}) {
    _doc = doc;
    _docGeneration++;
    _editRevision++;
    _chapterIndex = 0;
    _path = TreePath.empty;
    _faceChapterOrientation();
    _dirty = dirty;
    _autoSaveBlocked = dirty;
    _recoveryPath = null;
  }

  // ── Chapters ─────────────────────────────────────────────────────────

  void selectChapter(int index) {
    if (index < 0 || index >= _doc.chapters.length) return;
    _chapterIndex = index;
    _path = TreePath.empty;
    _faceChapterOrientation();
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

  /// Name for a chapter added without one: "Chapter N" past the last.
  String nextChapterName() => 'Chapter ${_doc.chapters.length + 1}';

  void addChapter(String name, {String? startingFen, Side? orientation}) {
    _doc.chapters.add(
      StudyChapter(
        name: name.trim().isEmpty ? nextChapterName() : name.trim(),
        startingFen: startingFen,
        orientation: orientation,
      ),
    );
    _chapterIndex = _doc.chapters.length - 1;
    _path = TreePath.empty;
    _faceChapterOrientation();
    _markDirty();
  }

  /// Append every game in [pgn] as a new chapter (Lichess-style PGN import).
  /// Chapter names come from the `[ChapterName]` / `[Event]` tags (see
  /// [StudyChapter.nameFromHeaders]) unless [name] is given, which names a
  /// single game outright and numbers several.  [orientation] overrides the
  /// file's `[Orientation]` tags.  `[FEN]` starting positions and comments
  /// are preserved.  Returns the number of chapters added (0 when [pgn] holds
  /// no parseable games), selecting the first new chapter and persisting
  /// immediately.
  /// Capture the destination before native I/O so a late import cannot attach
  /// chapters to a different study opened while its source was being read.
  Future<int> importFile(String path) async {
    final document = _doc;
    final opened = await _documents.open(path);
    if (isDisposed || !identical(document, _doc)) return 0;
    if (opened is! PgnOpened) {
      throw StateError('Could not read the imported PGN');
    }
    return importChapters(opened.snapshot.content);
  }

  Future<List<RepertoireMetadata>> listStudies() => _library.list();

  Future<int> importChapters(
    String pgn, {
    String? name,
    Side? orientation,
  }) async {
    // Off-isolate for the same reason as [openStudy]; ids re-minted on adopt.
    final document = _doc;
    final games = await compute(_parseChapterTreesEntry, pgn);
    if (isDisposed || !identical(document, _doc)) return 0;
    final usable = [
      // Skip fragments that are neither a game nor a headered stub.
      for (final game in games)
        if (!(game.$2.isEmpty && game.$1.isEmpty)) game,
    ];
    final firstNewIndex = _doc.chapters.length;
    final givenName = name?.trim();
    for (final (i, (headers, tree)) in usable.indexed) {
      final chapterName = givenName == null || givenName.isEmpty
          ? StudyChapter.nameFromHeaders(
              headers,
              fallback: nextChapterName(),
              studyName: _doc.name,
            )
          : usable.length == 1
          ? givenName
          : '$givenName ${i + 1}';
      _doc.chapters.add(
        StudyChapter(
          name: chapterName,
          headers: headers,
          tree: tree.copyWithFreshIds(),
          orientation: orientation,
        ),
      );
    }
    if (usable.isNotEmpty) {
      _chapterIndex = firstNewIndex;
      _path = TreePath.empty;
      _faceChapterOrientation();
      _markDirty();
      // Only a study with a file can fail to reach one. A study that has not
      // been saved yet has nowhere to write, which is not an import error —
      // the chapters are in the document either way.
      if (_doc.filePath != null && !await flushSave()) {
        throw StateError(saveError ?? 'Study not saved');
      }
    }
    return usable.length;
  }

  /// Change a chapter's name, orientation and/or preserved PGN tags — the
  /// Lichess "Edit chapter" dialog.  Owned tags in [headers] are ignored
  /// (they are regenerated on save).  Changing the open chapter's
  /// orientation turns the board at once.
  void updateChapter(
    int index, {
    String? name,
    Side? orientation,
    Map<String, String>? headers,
  }) {
    if (index < 0 || index >= _doc.chapters.length) return;
    final target = _doc.chapters[index];
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isNotEmpty) target.name = trimmed;
    if (orientation != null) target.orientation = orientation;
    if (headers != null) {
      target.headers
        ..clear()
        ..addAll({
          for (final entry in headers.entries)
            if (!StudyChapter.ownedHeaders.contains(entry.key.trim()) &&
                entry.key.trim().isNotEmpty)
              entry.key.trim(): entry.value,
        });
    }
    if (index == _chapterIndex) _faceChapterOrientation();
    _markDirty();
  }

  void renameChapter(int index, String name) =>
      updateChapter(index, name: name);

  /// Remove every comment, glyph and drawn shape from a chapter, keeping
  /// the moves.
  void clearChapterAnnotations(int index) {
    if (index < 0 || index >= _doc.chapters.length) return;
    _doc.chapters[index].tree.clearAnnotations();
    _projections.changed(_doc.chapters[index]);
    _markDirty();
  }

  /// Remove every sideline from a chapter, keeping the mainline.  A cursor
  /// parked on a deleted sideline retreats to its last mainline ancestor.
  void clearChapterVariations(int index) {
    if (index < 0 || index >= _doc.chapters.length) return;
    final sanLine = index == _chapterIndex ? _tree.sanSequenceAt(_path) : null;
    _doc.chapters[index].tree.clearVariations();
    _projections.changed(_doc.chapters[index]);
    if (sanLine != null) _reanchorCursor(sanLine);
    _markDirty();
  }

  /// Replace the current chapter's starting position with [fen]. The
  /// chapter's moves are cleared — they were rooted in the old position.
  void setChapterStartingPosition(String fen) {
    final old = _chapter;
    _doc.chapters[_chapterIndex] = StudyChapter(
      name: old.name,
      headers: Map<String, String>.from(old.headers),
      startingFen: fen,
      // The moves belonged to the old position; the chapter's own note did
      // not, so it stays.
      intro: old.intro,
      orientation: old.orientation,
    );
    _path = TreePath.empty;
    _markDirty();
  }

  /// Whether the current chapter has any moves (something to train).
  bool get chapterHasMoves => _tree.roots.isNotEmpty;

  void deleteChapter(int index) {
    if (_doc.chapters.length <= 1) return; // keep at least one
    if (index < 0 || index >= _doc.chapters.length) return;
    final active = _chapter;
    _doc.chapters.removeAt(index);
    final activeIndex = _doc.chapters.indexOf(active);
    if (activeIndex >= 0) {
      _chapterIndex = activeIndex;
    } else {
      _chapterIndex = index.clamp(0, _doc.chapters.length - 1);
      _path = TreePath.empty;
      _faceChapterOrientation();
    }
    _markDirty();
  }

  // ── Navigation ───────────────────────────────────────────────────────

  /// Jump the cursor to [target].  All navigation funnels here.
  /// (goBack / goForward / goToStart / goToEnd come from [MoveNavigation].)
  @override
  void jump(TreePath target) {
    if (!_tree.isValidPath(target)) return;
    if (_path == target) return;
    _path = TreePath.from(target.indices);
    notifyListeners();
  }

  void toggleFlipped() {
    _flipped = !_flipped;
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
    final version = _tree.version;
    final path = _tree.addMove(_path, san);
    if (path == null) return false;
    _path = path;
    if (_tree.version == version) {
      notifyListeners();
    } else {
      _projections.changed(_chapter, path: path);
      _markDirty();
    }
    return true;
  }

  void setComment(TreePath path, String? comment) {
    final version = _tree.version;
    _tree.setComment(path, comment);
    if (_tree.version != version) {
      _projections.changed(_chapter, path: path);
      _markDirty();
    }
  }

  /// Comment at the cursor, annotation tokens and all — the chapter's
  /// introduction ([MoveTree.rootComment]) when the cursor is on the start
  /// position.
  ///
  /// Board shapes (`[%cal]`/`[%csl]` arrows and circles) live in here, so the
  /// study screen reads and rewrites this rather than keeping shapes in a
  /// parallel structure that a PGN round-trip would drop.
  String? get cursorComment => _tree.commentAt(_path);

  void toggleNag(TreePath path, int nagId) {
    if (_tree.nodeAt(path) == null) return;
    _tree.toggleNag(path, nagId);
    _projections.changed(_chapter, path: path);
    _markDirty();
  }

  void deleteAt(TreePath path) {
    if (!_tree.isValidPath(path) || path.isEmpty && _tree.isEmpty) return;
    final sanLine = _tree.sanSequenceAt(_path);
    _tree.deleteAt(path);
    _projections.changed(_chapter, path: path.parent);
    // Surviving siblings shift indexes; a removed cursor retreats to the
    // deepest surviving ancestor instead of silently selecting another line.
    _reanchorCursor(sanLine);
    _markDirty();
  }

  void promote(TreePath path) {
    final sanLine = _tree.sanSequenceAt(_path);
    final version = _tree.version;
    _tree.promoteVariation(path);
    if (_tree.version == version) return;
    _projections.changed(_chapter, path: path.parent);
    _reanchorCursor(sanLine);
    _markDirty();
  }

  /// Recursively promote so [target] lies on the mainline (same algorithm as
  /// RepertoireController.makeMainLine).
  void makeMainLine(TreePath target) {
    if (target.isEmpty || !_tree.isValidPath(target) || target.isMainline) {
      return;
    }
    final sanLine = _tree.sanSequenceAt(_path);
    final indices = target.toList();
    for (int depth = 0; depth < indices.length; depth++) {
      if (indices[depth] != 0) {
        _tree.promoteVariation(TreePath(indices.sublist(0, depth + 1)));
        indices[depth] = 0;
      }
    }
    _reanchorCursor(sanLine);
    _projections.changed(_chapter);
    _markDirty();
  }

  /// After a structural change, re-locate the cursor by replaying its SAN
  /// sequence (paths shift when siblings reorder).
  void _reanchorCursor(List<String> sanLine) {
    _path = _tree.pathForSans(sanLine);
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    // Best-effort teardown follows app-owned close checks. Disposal must never
    // replay a known failed/uncertain write or a restored recovery draft.
    if (_dirty &&
        !_reloading &&
        !_relocating &&
        !_autoSaveBlocked &&
        _session.state.outcome == null) {
      unawaited(save());
    }
    unawaited(_sessionSubscription?.cancel());
    unawaited(_saveTail.then((_) => _session.dispose()));
    unawaited(_saveChanges.close());
    super.dispose();
  }
}

// ── compute() entry points ─────────────────────────────────────────────────
// PGN → MoveTree parsing replays every move with dartchess; big studies
// block long enough to freeze the UI, so the controller parses off-isolate.
// Trees crossing the isolate boundary carry foreign node ids — adopt them
// only via [MoveTree.copyWithFreshIds].

/// One record per game: its headers, its tree, and the note it opens with.
/// The intro travels with the rest because a chapter that arrives without it
/// is a chapter whose note the next autosave deletes.
List<(Map<String, String>, MoveTree)> _parseChapterTreesEntry(String pgn) {
  final games = splitPgnIntoGames(stripBom(pgn));
  return [
    // The tree carries the chapter's opening note itself (MoveTree.rootComment).
    for (final gameText in games)
      (extractHeaders(gameText), MoveTree.fromPgn(gameText)),
  ];
}

class StudyWriteException implements Exception {
  const StudyWriteException(this.result);
  final PgnWriteResult result;
  @override
  String toString() => 'Study was not confirmed saved: $result';
}

Future<StudyDocument> _decodeStudy(String content, String name, String path) =>
    Isolate.run(
      () => StudyDocument.fromPgn(content, name: name, filePath: path),
    );

StudyDocument _freshIds(StudyDocument loaded) => StudyDocument(
  name: loaded.name,
  filePath: loaded.filePath,
  chapters: [
    for (final c in loaded.chapters)
      StudyChapter(
        name: c.name,
        headers: c.headers,
        tree: c.tree.copyWithFreshIds(),
        orientation: c.orientation,
      ),
  ],
);
