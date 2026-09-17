import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../chess_core/moves/tree_path.dart';
import '../../../models/move_tree.dart';
import '../../../models/repertoire_line.dart';
import '../../../utils/safe_change_notifier.dart';
import '../../../utils/pgn_utils.dart' show escapeHeaderValue;
import '../../../constants/chess_constants.dart';
import '../models/builder_workspace_snapshot.dart';
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
    required RepertoireDocumentRepository documents,
    required RepertoireDecoder decoder,
  }) {
    document = RepertoireDocumentSession(
      documents: documents,
      decoder: decoder,
      onChanged: _documentChanged,
      onLoadStarted: () {
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
  final board = RepertoireBoardController();
  late final RepertoireDocumentSession document;
  late final RepertoireWriter writer;
  final Map<String, BuilderDraft> _drafts = {};
  bool _suspended = false;
  bool _dirty = false;
  int _boardStructure = 0;
  int _draftSequence = 0;
  bool sourceChanged = false;
  int _documentRevision = 0;
  String? _activeKey;
  String _title = 'Repertoire Line';
  String? _label;
  String get title => _title;
  String? get annotatedLineLabel => _label;
  Object? saveError;
  Future<bool> Function(String)? _saveLine;
  int _editRevision = 0;
  bool _closed = false;
  int get structureVersion => _documentRevision + board.structureVersion;
  Object get closeRevision =>
      (document.closeRevision, board.closeRevision, _editRevision);
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

  void _boardChanged() {
    document.syncOpeningTree(board.moveHistory, board.cursorFens);
    if (!_suspended) {
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

  String _content() {
    final headers = <String, String>{...?document.selectedPgnLine?.headers};
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
    return '${[for (final entry in headers.entries) '[${entry.key} "${escapeHeaderValue(entry.value)}"]'].join('\n')}\n\n${board.tree.toPgnMoveText()}';
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
    _captureDraft();
    _saveLine = null;
    document.selectLine(line);
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
    _captureDraft();
    var accepted = false;
    _withoutCapture(() => accepted = board.setPositionFromFen(fen));
    if (!accepted) return false;
    _saveLine = null;
    document.selectLine(null);
    _activeKey = null;
    _title = 'Repertoire Line';
    _label = null;
    _dirty = true;
    _editRevision++;
    _captureDraft();
    notifyListeners();
    return true;
  }

  void composeMoves(List<String> moves) {
    _captureDraft();
    _saveLine = null;
    document.selectLine(null);
    _activeKey = null;
    _title = 'Repertoire Line';
    _label = null;
    _withoutCapture(() => board.loadMoveSequence(moves));
    _dirty = true;
    _editRevision++;
    _captureDraft();
    notifyListeners();
  }

  void inspectAnnotatedTree(MoveTree tree, {TreePath? cursor, String? label}) {
    _captureDraft();
    _saveLine = null;
    document.selectLine(null);
    _activeKey = null;
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

  Future<void> saveScratchToChapter() async {
    if (document.currentRepertoire == null || document.isLoading) return;
    final key = _key;
    final content = _content();
    try {
      await document.appendDraft(content);
      _drafts.remove(key);
      saveError = null;
      sourceChanged = false;
      notifyListeners();
    } catch (error) {
      saveError = error;
      notifyListeners();
      rethrow;
    }
  }

  BuilderWorkspaceSnapshot captureWorkspace() {
    _captureDraft();
    return BuilderWorkspaceSnapshot(
      drafts: _drafts.values.toList(),
      activeKey: _drafts.containsKey(_activeKey) ? _activeKey : null,
    );
  }

  Future<void> restoreWorkspace(BuilderWorkspaceSnapshot snapshot) async {
    _captureDraft();
    for (final draft in snapshot.drafts) {
      _drafts.putIfAbsent(draft.key, () => draft);
    }
    if (snapshot.drafts.isEmpty) return;
    await openRetainedDraft(
      _drafts[snapshot.activeKey] ?? snapshot.drafts.first,
    );
  }

  Future<void> openRetainedDraft(BuilderDraft draft) async {
    _captureDraft();
    _saveLine = null;
    if (draft.repertoire != null) {
      await document.setRepertoire(draft.repertoire!);
      if (document.currentRepertoire != draft.repertoire ||
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
    _applyDraft(draft);
    notifyListeners();
  }

  void _applyDraft(BuilderDraft draft) {
    final parsed = MoveTree.fromPgn(draft.content);
    _withoutCapture(
      () => board.loadAnnotatedTree(parsed, cursor: TreePath(draft.cursor)),
    );
    _activeKey = draft.key;
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
