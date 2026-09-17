import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../chess_core/moves/tree_path.dart';
import '../../../chess_core/pgn/pgn_parser.dart';
import '../../../models/move_tree.dart';
import '../../../models/repertoire_line.dart';
import '../../../utils/safe_change_notifier.dart';
import '../../../utils/pgn_utils.dart' show escapeHeaderValue;
import '../../../constants/chess_constants.dart';
import '../models/builder_workspace_snapshot.dart';
import '../models/repertoire_metadata.dart';
import '../../documents/models/pgn_document.dart';
import '../repositories/repertoire_decoder.dart';
import '../repositories/repertoire_document_repository.dart';
import 'repertoire_board_controller.dart';
import 'repertoire_document_session.dart';
import 'repertoire_writer.dart';

/// Owns Builder's editable workspace and retained chapter drafts. Callers use
/// [board], [document] and [writer] directly for their respective commands.
/// Workspace transitions capture outgoing work before changing its destination.
class BuilderWorkspaceController extends ChangeNotifier
    with SafeChangeNotifier {
  BuilderWorkspaceController({
    required this.checkpoint,
    required RepertoireDocumentRepository documents,
    required RepertoireDecoder decoder,
  }) {
    document = RepertoireDocumentSession(
      documents: documents,
      decoder: decoder,
      onChanged: _documentChanged,
      onLoadStarted: () {
        _intentRevision++;
        _captureDraft();
        writer.invalidatePendingActions();
      },
      onResetBoard: () {
        writer.clearUndoStack();
        _saveLine = null;
        _withoutCapture(() {
          board.reset();
        });
        _activeKey = null;
        _dirty = false;
        sourceChanged = false;
        saveError = null;
        _headers = const {};
        _title = 'Repertoire Line';
        _label = null;
      },
      onClearSelectionAndTree: () {
        _captureDraft();
        document.selectLine(null);
        _withoutCapture(board.clearMoveHistory);
        _activeKey = null;
        _dirty = false;
      },
      onNavigate: (moves) =>
          _withoutCapture(() => board.navigateToLineMove(moves)),
      onNavigateToRoot: () => _withoutCapture(
        () => board.navigateToRootPosition(document.rootMoves),
      ),
      startingFen: () => board.startingFen,
      currentMoveSequence: () => board.currentMoveSequence,
    );
    writer = RepertoireWriter(
      document: document,
      board: board,
      documents: documents,
    );
    board.addListener(_boardChanged);
  }
  final Future<void> Function() checkpoint;
  final board = RepertoireBoardController();
  final Map<String, BuilderCopyUncertainty> _uncertainCopies = {};
  final Set<String> _pendingCopies = {};
  final Map<String, int> _copyFailureRevisions = {};
  List<BuilderCopyUncertainty> get uncertainCopies =>
      List.unmodifiable(_uncertainCopies.values);
  bool copyInProgress(String key) => _pendingCopies.contains(key);
  late final RepertoireDocumentSession document;
  late final RepertoireWriter writer;
  final Map<String, BuilderDraft> _drafts = {};
  bool _suspended = false;
  bool _dirty = false;
  int _boardStructure = 0;
  int _draftSequence = 0;
  int _intentRevision = 0;
  bool sourceChanged = false;
  int _documentRevision = 0;
  String? _activeKey;
  String _title = 'Repertoire Line';
  Map<String, String> _headers = const {};
  String? _label;
  String get title => _title;
  String? get annotatedLineLabel => _label;
  Object? saveError;
  Future<bool> Function(String)? _saveLine;
  int _editRevision = 0;
  bool _closed = false;
  int get structureVersion => _documentRevision + board.structureVersion;
  Object get closeRevision =>
      (document.closeRevision, board.revision, _editRevision);
  List<BuilderDraft> get retainedDrafts => List.unmodifiable(_drafts.values);

  void _withoutCapture(void Function() action) {
    final was = _suspended;
    _suspended = true;
    try {
      action();
    } finally {
      _suspended = was;
      _boardStructure = board.structureVersion;
    }
  }

  void _documentChanged() {
    _documentRevision++;
    notifyListeners();
  }

  void _beginUserIntent() {
    _intentRevision++;
    document.cancelPendingLoad();
  }

  void _boardChanged() {
    document.syncOpeningTree(board.moveHistory, board.cursorFens);
    if (!_suspended) {
      _beginUserIntent();
      final changed = _boardStructure != board.structureVersion;
      _boardStructure = board.structureVersion;
      if (changed) {
        _dirty = true;
        _editRevision++;
      }
      _captureDraft();
      if (changed && _saveLine != null) unawaited(saveActiveLine());
    }
    if (!_suspended) notifyListeners();
  }

  String get _key {
    if (_activeKey != null) return _activeKey!;
    final prefix = document.currentRepertoire?.filePath ?? '';
    final line = document.selectedPgnLine;
    if (line != null) return _activeKey = '$prefix\u0000${line.id}';
    String key;
    do {
      key = '$prefix\u0000scratch-${++_draftSequence}';
    } while (_drafts.containsKey(key));
    return _activeKey = key;
  }

  Object? _serializedRevision;
  String? _serializedContent;
  String _content() {
    final revision = (board.structureVersion, _title, _headers);
    if (_serializedRevision == revision) return _serializedContent!;
    final headers = <String, String>{..._headers};
    headers['Event'] = _title;
    headers.putIfAbsent(
      'White',
      () => document.isRepertoireWhite ? 'Me' : 'Training',
    );
    headers.putIfAbsent(
      'Black',
      () => document.isRepertoireWhite ? 'Training' : 'Me',
    );
    headers.putIfAbsent('Result', () => '*');
    if (board.tree.startingFen != kStandardStartFen) {
      headers['FEN'] = board.tree.startingFen;
      headers['SetUp'] = '1';
    }
    _serializedRevision = revision;
    return _serializedContent =
        '${[for (final entry in headers.entries) '[${entry.key} "${escapeHeaderValue(entry.value)}"]'].join('\n')}\n\n${board.tree.toPgnMoveText()}';
  }

  void _captureDraft() {
    if (!_dirty || _suspended) return;
    _drafts[_key] = BuilderDraft(
      key: _key,
      repertoire: document.currentRepertoire,
      content: _content(),
      sourcePgn: document.repertoirePgn,
      lineId: document.selectedPgnLine?.id,
      linePgn: document.selectedPgnLine?.fullPgn,
      title: _title,
      cursor: board.path.toList(),
      label: _label,
    );
  }

  void setTitle(String title) {
    if (_title == title) return;
    _beginUserIntent();
    _title = title;
    _dirty = true;
    _editRevision++;
    _captureDraft();
    notifyListeners();
    if (_saveLine != null) unawaited(saveActiveLine());
  }

  Future<bool> saveActiveLine() async {
    final save = _saveLine;
    if (save == null) return false;
    final revision = _editRevision;
    final key = _key;
    final content = _content();
    try {
      if (!await save(content))
        throw StateError('The original line is unavailable.');
      if (_closed) return true;
      if (_drafts[key]?.content == content) _drafts.remove(key);
      if (revision == _editRevision && key == _activeKey) {
        _dirty = false;
        saveError = null;
      }
      notifyListeners();
      return true;
    } catch (error) {
      if (!_closed && key == _activeKey) {
        saveError = error;
        notifyListeners();
      }
      return false;
    }
  }

  void selectLine(RepertoireLine line) {
    _beginUserIntent();
    _captureDraft();
    _saveLine = null;
    document.selectLine(line);
    sourceChanged = false;
    saveError = null;
    _headers = Map.unmodifiable(line.headers);
    _title = line.name;
    _label = null;
    _activeKey =
        '${document.currentRepertoire?.filePath ?? ''}\u0000${line.id}';
    _dirty = false;
    _withoutCapture(() => board.loadPgnLine(line));
    _saveLine = document.selectedLineSaver;
    final retained = _drafts[_activeKey];
    if (retained != null) _applyDraft(retained);
    notifyListeners();
  }

  bool composePosition(String fen) {
    _beginUserIntent();
    _captureDraft();
    var accepted = false;
    _withoutCapture(() => accepted = board.setPositionFromFen(fen));
    if (!accepted) return false;
    _saveLine = null;
    document.selectLine(null);
    _activeKey = null;
    _headers = const {};
    _title = 'Repertoire Line';
    _label = null;
    _dirty = true;
    _editRevision++;
    _captureDraft();
    notifyListeners();
    return true;
  }

  void composeMoves(List<String> moves) {
    _beginUserIntent();
    _captureDraft();
    _saveLine = null;
    document.selectLine(null);
    _activeKey = null;
    _headers = const {};
    _title = 'Repertoire Line';
    _label = null;
    _withoutCapture(() => board.loadMoveSequence(moves));
    _dirty = true;
    _editRevision++;
    _captureDraft();
    notifyListeners();
  }

  void inspectAnnotatedTree(MoveTree tree, {TreePath? cursor, String? label}) {
    _beginUserIntent();
    _captureDraft();
    _saveLine = null;
    document.selectLine(null);
    _activeKey = null;
    _headers = const {};
    _title = 'Repertoire Line';
    _label = label;
    _withoutCapture(() => board.loadAnnotatedTree(tree, cursor: cursor));
    _dirty = true;
    _editRevision++;
    _captureDraft();
    notifyListeners();
  }

  void deleteDraftBranch(TreePath path) {
    final edit = board.deleteAtPath(path);
    if (edit != null)
      writer.recordDraftUndo(
        isCurrent: () => board.canRestore(edit),
        restore: () => board.restore(edit),
      );
  }

  Future<void> saveDraftToChapter(
    BuilderDraft draft,
    RepertoireMetadata destination,
  ) async {
    if (_uncertainCopies.containsKey(draft.key) ||
        !_pendingCopies.add(draft.key)) {
      throw StateError(
        'Inspect the previous copy before trying another append.',
      );
    }
    _drafts.putIfAbsent(draft.key, () => draft);
    final intent = _intentRevision;
    final edit = _editRevision;
    _copyFailureRevisions[draft.key] = document.lineSaveRevision;
    var publishing = false;
    _uncertainCopies[draft.key] = BuilderCopyUncertainty(
      draftKey: draft.key,
      destination: destination.filePath,
      content: draft.content,
      outcome: const PgnWriteUncertain(
        error: 'Copy interrupted before acknowledgement.',
        before: null,
        observed: null,
      ),
    );
    notifyListeners();
    try {
      // This intent must be durable before the destination namespace can change.
      await checkpoint();
      publishing = true;
      final result = await document.appendDraftTo(
        destination.filePath,
        draft.content,
      );
      switch (result) {
        case PgnWriteUncertain():
          _uncertainCopies[draft.key] = BuilderCopyUncertainty(
            draftKey: draft.key,
            destination: destination.filePath,
            content: draft.content,
            outcome: result,
          );
          notifyListeners();
          await checkpoint();
          return;
        case PgnSaved():
          _resolveCopiedDraft(_uncertainCopies[draft.key]!);
        case PgnWriteFailed(:final error):
          _uncertainCopies.remove(draft.key);
          throw error;
        case PgnConflict():
          _uncertainCopies.remove(draft.key);
          throw StateError('The copy destination changed.');
        case PgnNameCollision():
          _uncertainCopies.remove(draft.key);
          throw StateError('The copy destination already exists.');
      }
      if (intent == _intentRevision &&
          edit == _editRevision &&
          document.currentRepertoire?.filePath == destination.filePath) {
        await document.loadRepertoire();
      }
      notifyListeners();
      await checkpoint();
    } catch (error) {
      if (!publishing) _uncertainCopies.remove(draft.key);
      if (intent == _intentRevision &&
          edit == _editRevision &&
          _activeKey == draft.key) {
        saveError = error;
        notifyListeners();
      }
      rethrow;
    } finally {
      _pendingCopies.remove(draft.key);
      notifyListeners();
    }
  }

  void _resolveCopiedDraft(BuilderCopyUncertainty copy) {
    _uncertainCopies.remove(copy.draftKey);
    if (_drafts[copy.draftKey]?.content == copy.content)
      _drafts.remove(copy.draftKey);
    if (_activeKey == copy.draftKey && _content() == copy.content) {
      _dirty = false;
      saveError = null;
      sourceChanged = false;
      document.resolveCopiedLineFailure(
        _copyFailureRevisions.remove(copy.draftKey) ?? -1,
      );
    }
  }

  /// A fresh native observation may prove installation or prove that the old
  /// namespace remains untouched. Equal PGN text by itself proves neither.
  Future<PgnOpenResult> inspectCopy(BuilderCopyUncertainty copy) async {
    if (_pendingCopies.contains(copy.draftKey))
      return PgnReadFailed(StateError('Copy still pending.'));
    final result = await document.documents.read(copy.destination);
    if (!identical(_uncertainCopies[copy.draftKey], copy)) return result;
    if (result case PgnOpened(:final snapshot)) {
      if (copy.outcome.installedRevision != null &&
          snapshot.revision == copy.outcome.installedRevision) {
        _resolveCopiedDraft(copy);
      } else if (copy.outcome.before != null &&
          snapshot.revision == copy.outcome.before!.revision) {
        _uncertainCopies.remove(copy.draftKey);
      } else {
        _uncertainCopies[copy.draftKey] = BuilderCopyUncertainty(
          draftKey: copy.draftKey,
          destination: copy.destination,
          content: copy.content,
          outcome: PgnWriteUncertain(
            error: copy.outcome.error,
            before: copy.outcome.before,
            observed: snapshot,
            installedRevision: copy.outcome.installedRevision,
            recoveryPath: copy.outcome.recoveryPath,
          ),
        );
      }
    }
    notifyListeners();
    await checkpoint();
    return result;
  }

  /// Explicit user acknowledgement after inspecting the observed copy. No
  /// append is retried and no document bytes are changed by this decision.
  Future<void> acknowledgeInspectedCopy(BuilderCopyUncertainty copy) async {
    if (_pendingCopies.contains(copy.draftKey) ||
        !identical(_uncertainCopies[copy.draftKey], copy) ||
        copy.outcome.observed == null)
      return;
    _resolveCopiedDraft(copy);
    notifyListeners();
    await checkpoint();
  }

  BuilderWorkspaceSnapshot captureWorkspace() {
    _captureDraft();
    return BuilderWorkspaceSnapshot(
      drafts: _drafts.values.toList(),
      uncertainCopies: _uncertainCopies.values.toList(),
      activeKey: _drafts.containsKey(_activeKey) ? _activeKey : null,
    );
  }

  Future<void> restoreWorkspace(BuilderWorkspaceSnapshot snapshot) async {
    _captureDraft();
    final restored = <String, BuilderDraft>{};
    for (final incoming in snapshot.drafts) {
      var draft = incoming;
      final existing = _drafts[draft.key];
      if (existing != null && existing.content != draft.content) {
        String key;
        do {
          key = '${draft.key}\u0000recovered-${++_draftSequence}';
        } while (_drafts.containsKey(key));
        draft = draft.withKey(key);
      }
      _drafts[draft.key] = draft;
      restored[incoming.key] = draft;
    }
    for (final copy in snapshot.uncertainCopies) {
      final key = restored[copy.draftKey]?.key ?? copy.draftKey;
      _uncertainCopies[key] = copy.withKey(key);
    }
    if (restored.isEmpty) {
      notifyListeners();
      return;
    }
    await openRetainedDraft(
      restored[snapshot.activeKey] ?? restored.values.first,
    );
  }

  Future<void> openRetainedDraft(BuilderDraft draft) async {
    final parsed = MoveTree.fromPgn(draft.content);
    if (!parsed.isValidPath(TreePath(draft.cursor))) {
      throw const FormatException(
        'Recovered Builder cursor does not belong to its tree.',
      );
    }
    _captureDraft();
    if (draft.repertoire != null) {
      final loading = document.setRepertoire(draft.repertoire!);
      final intent = _intentRevision;
      await loading;
      if (intent != _intentRevision ||
          document.currentRepertoire != draft.repertoire ||
          document.loadError != null) {
        throw StateError(
          'The draft destination could not be opened. Its checkpoint is retained.',
        );
      }
    }
    // Only an exact source match may reattach a recovered editor to autosave.
    // Changed/missing sources retain the tree as scratch for an explicit save.
    RepertoireLine? target;
    if (document.repertoirePgn == draft.sourcePgn) {
      for (final line in document.repertoireLines) {
        if (line.id == draft.lineId && line.fullPgn == draft.linePgn)
          target = line;
      }
    }
    sourceChanged = draft.lineId != null && target == null;
    document.selectLine(target);
    _saveLine = target == null ? null : document.selectedLineSaver;
    _applyDraft(draft, parsed: parsed);
    notifyListeners();
  }

  void _applyDraft(BuilderDraft draft, {MoveTree? parsed}) {
    parsed ??= MoveTree.fromPgn(draft.content);
    if (!parsed.isValidPath(TreePath(draft.cursor))) {
      throw const FormatException(
        'Recovered Builder cursor does not belong to its tree.',
      );
    }
    _withoutCapture(
      () => board.loadAnnotatedTree(parsed!, cursor: TreePath(draft.cursor)),
    );
    _activeKey = draft.key;
    _headers = Map.unmodifiable(parsePgnGame(draft.content).headers);
    _title = draft.title;
    _label = draft.label;
    _dirty = true;
    _editRevision++;
  }

  @override
  void dispose() {
    _closed = true;
    board.removeListener(_boardChanged);
    board.dispose();
    document.dispose();
    writer.clearUndoStack();
    super.dispose();
  }
}
