/// Centralized repertoire session state shared across board, PGN, engine, and tree.
///
/// Coordinates document loading/writing with a pure [RepertoireBoardController].
/// UI components read immutable board projections through this notifier.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../../chess_core/moves/move_navigation.dart';
import '../../../chess_core/moves/move_tree_snapshot.dart';
import '../../../chess_core/moves/tree_path.dart';
import '../../../models/move_tree.dart';
import '../../../chess_core/moves/opening_graph.dart';
import '../../../models/repertoire_line.dart';
import '../../../utils/safe_change_notifier.dart';
import '../../../utils/san_token_utils.dart';
import '../../documents/models/pgn_document.dart';
import '../models/repertoire_metadata.dart';
import '../repositories/repertoire_decoder.dart';
import '../repositories/repertoire_document_repository.dart';
import 'repertoire_board_controller.dart';
import 'repertoire_document_session.dart';
import 'repertoire_writer.dart';

/// Manages repertoire state and acts as the single source of truth.
/// All UI components should derive their chess position from this class.
class RepertoireController
    with ChangeNotifier, MoveNavigation, SafeChangeNotifier {
  RepertoireController({required this.documents, required this.decoder});

  final RepertoireDocumentRepository documents;
  final RepertoireDecoder decoder;
  late final RepertoireWriter writer = RepertoireWriter(
    this,
    documents: documents,
  );

  late final RepertoireDocumentSession _document = RepertoireDocumentSession(
    documents: documents,
    decoder: decoder,
    onChanged: _notifyStructureChanged,
    onLoadStarted: () => writer.invalidatePendingActions(),
    onResetBoard: () {
      writer.clearUndoStack();
      _annotatedLineLabel = null;
      _board.reset();
      _syncOpeningTree();
    },
    onClearSelectionAndTree: _clearSelectionAndTree,
    onNavigate: navigateToLineMove,
    onNavigateToRoot: _navigateToRootPosition,
    startingFen: () => startingFen,
    currentMoveSequence: () => currentMoveSequence,
  );

  Future<T> runDocumentMutation<T>(Future<T> Function() action) =>
      _document.runDocumentMutation(action);

  RepertoireMetadata? get currentRepertoire => _document.currentRepertoire;
  String? get repertoirePgn => _document.repertoirePgn;
  OpeningGraph? get openingGraph => _document.openingGraph;
  List<RepertoireLine> get repertoireLines => _document.repertoireLines;
  bool get isLoading => _document.isLoading;
  String? get loadError => _document.loadError;
  void dismissLoadError() => _document.dismissLoadError();
  bool get isRepertoireWhite => _document.isRepertoireWhite;
  bool get needsColorSelection => _document.needsColorSelection;
  String get rootMoves => _document.rootMoves;
  RepertoireLine? get selectedPgnLine => _document.selectedPgnLine;

  final RepertoireBoardController _board = RepertoireBoardController();
  @override
  MoveTreeSnapshot get tree => _board.tree;
  @override
  TreePath get path => _board.path;
  List<String> get moveHistory => _board.moveHistory;
  List<String> get currentMoveSequence => moveHistory;
  int get currentMoveIndex => _board.currentMoveIndex;
  String get fen => _board.fen;
  Position get position => _board.position;
  String? get startingFen => _board.startingFen;
  List<String> get rootMoveSans => cleanSanTokens(rootMoves);
  String get rootFen => _board.rootFen(rootMoves);
  bool get isAtRootPosition => _board.isAtRootPosition(rootMoves);
  Set<String> recentMoveTrail({int lastN = 1}) =>
      _board.recentMoveTrail(lastN: lastN);

  int _structureVersion = 0;
  int get structureVersion => _structureVersion;
  void _notifyStructureChanged() {
    _structureVersion++;
    notifyListeners();
  }

  /// The pure owner finishes the command before the host exposes its state.
  void _changeBoard(void Function() action) {
    final revision = _board.revision;
    final structure = _board.structureVersion;
    action();
    if (_board.revision == revision) return;
    _syncOpeningTree();
    if (_board.structureVersion != structure) {
      _notifyStructureChanged();
    } else {
      notifyListeners();
    }
  }

  void _syncOpeningTree() =>
      _document.syncOpeningTree(_board.moveHistory, _board.cursorFens);

  @override
  void jump(TreePath target) => _changeBoard(() => _board.jump(target));
  void playMove(String san) => _changeBoard(() => _board.playMove(san));
  void playMoveAtTreePath(TreePath path, String san) =>
      _changeBoard(() => _board.playMoveAtTreePath(path, san));
  void userSelectedTreeMove(String san) => playMove(san);
  void navigateToLineMove(List<String> moves, {int? targetIndex}) =>
      _changeBoard(
        () => _board.navigateToLineMove(moves, targetIndex: targetIndex),
      );
  void applyLineFromCurrent(List<String> moves, int index) =>
      _changeBoard(() => _board.applyLineFromCurrent(moves, index));
  void jumpToMoveIndex(int index) =>
      _changeBoard(() => _board.jumpToMoveIndex(index));

  void loadMoveHistory(List<String> moves) {
    _annotatedLineLabel = null;
    _changeBoard(() => _board.loadMoveHistory(moves));
  }

  void clearMoveHistory() {
    _annotatedLineLabel = null;
    _changeBoard(_board.clearMoveHistory);
  }

  bool setPositionFromFen(String fen) {
    var accepted = false;
    _changeBoard(() {
      accepted = _board.setPositionFromFen(fen);
      if (accepted) {
        _document.selectLine(null);
        _annotatedLineLabel = null;
      }
    });
    return accepted;
  }

  bool setPositionFromMoveHistory({
    required String fen,
    required List<String> moves,
    String? startingFen,
  }) {
    var accepted = false;
    _changeBoard(() {
      accepted = _board.setPositionFromMoveHistory(
        fen: fen,
        moves: moves,
        startingFen: startingFen,
      );
      if (accepted) {
        _document.selectLine(null);
        _annotatedLineLabel = null;
      }
    });
    return accepted;
  }

  void loadPgnLine(RepertoireLine line) {
    _document.selectLine(line);
    _annotatedLineLabel = null;
    _changeBoard(() => _board.loadPgnLine(line));
  }

  void loadMoveSequence(List<String> moves) {
    _document.selectLine(null);
    _annotatedLineLabel = null;
    _changeBoard(() => _board.loadMoveSequence(moves));
  }

  String? _annotatedLineLabel;
  String? get annotatedLineLabel => _annotatedLineLabel;
  void loadAnnotatedTree(MoveTree tree, {TreePath? cursor, String? label}) {
    _document.selectLine(null);
    _annotatedLineLabel = label;
    _changeBoard(() => _board.loadAnnotatedTree(tree, cursor: cursor));
  }

  void syncFromMoveIndex(int index, List<String> moves) =>
      _changeBoard(() => _board.syncFromMoveIndex(index, moves));

  void deleteAtPath(TreePath target) {
    _changeBoard(() {
      final edit = _board.deleteAtPath(target);
      if (edit == null) return;
      writer.recordDraftUndo(
        isCurrent: () => _board.canRestore(edit),
        restore: () => _changeBoard(() {
          _board.restore(edit);
        }),
      );
    });
  }

  void promoteVariation(TreePath target) =>
      _changeBoard(() => _board.promoteVariation(target));
  void makeMainLine(TreePath target) =>
      _changeBoard(() => _board.makeMainLine(target));
  void setCommentAtPath(TreePath target, String? comment) =>
      _changeBoard(() => _board.setCommentAtPath(target, comment));
  void toggleNagAtPath(TreePath target, int nag) =>
      _changeBoard(() => _board.toggleNagAtPath(target, nag));

  void _navigateToRootPosition() {
    _board.navigateToRootPosition(rootMoves);
    _syncOpeningTree();
  }

  /// Forget the selected line and drop the editable tree.
  void _clearSelectionAndTree() {
    _document.selectLine(null);
    _annotatedLineLabel = null;
    _board.clearMoveHistory();
    _syncOpeningTree();
  }

  void clearSelectedPgnLine() => _document.clearSelectedPgnLine();
  Future<bool> deleteLine(RepertoireLine line) => _document.deleteLine(line);
  Future<int> deleteLines(Iterable<RepertoireLine> lines) =>
      _document.deleteLines(lines);
  void setPendingLineSave(VoidCallback? flush) =>
      _document.setPendingLineSave(flush);
  Future<void> flushDocumentForClose() => _document.flushDocumentForClose();
  Object get closeRevision => (_document.closeRevision, _board.closeRevision);
  Future<bool> Function(String)? get selectedLineSaver =>
      _document.selectedLineSaver;
  Future<bool> updateSelectedLineContent(String pgn) =>
      _document.updateSelectedLineContent(pgn);
  void appendNewLine(
    List<String> moves,
    String title,
    String pgnContent, {
    bool updateTree = true,
    bool notify = true,
  }) => _document.appendNewLine(
    moves,
    title,
    pgnContent,
    updateTree: updateTree,
    notify: notify,
  );
  Future<void> Function(PgnSnapshot) get publishedDocumentReceiver =>
      _document.publishedDocumentReceiver;
  void appendMoveToExistingLine(
    List<String> prefix,
    String newMove, {
    String? updatedPgnContent,
  }) => _document.appendMoveToExistingLine(
    prefix,
    newMove,
    updatedPgnContent: updatedPgnContent,
  );
  Future<void> setRepertoire(RepertoireMetadata repertoire) =>
      _document.setRepertoire(repertoire);
  Future<void> loadRepertoire() => _document.loadRepertoire();
  Future<void> restoreRepertoireFromPgn(
    String pgnContent, {
    List<String>? syncPath,
  }) => _document.restoreRepertoireFromPgn(pgnContent, syncPath: syncPath);
  Future<void> setRepertoireColor(bool isWhite) =>
      _document.setRepertoireColor(isWhite);
  Future<void> setRootPosition() => _document.setRootPosition();
  Future<int> importPgnContent(String pgnContent) =>
      _document.importPgnContent(pgnContent);
  Future<void> awaitLoaded() => _document.awaitLoaded();

  @override
  void dispose() {
    _document.dispose();
    writer.clearUndoStack();
    super.dispose();
  }
}
