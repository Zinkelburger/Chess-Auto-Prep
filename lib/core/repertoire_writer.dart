/// Atomic repertoire mutations (one-click browse add, suggestion accept).
library;

import 'package:dartchess/dartchess.dart';

import '../features/coverage/services/coverage_suggestion_service.dart';
import '../services/repertoire_service.dart';
import '../services/storage/storage_factory.dart';
import 'repertoire_controller.dart';

/// Snapshot captured before a single browse/suggestion add for undo.
class UndoOperation {
  const UndoOperation({
    required this.previousPgn,
    required this.treePathBeforeAdd,
    required this.moveAdded,
  });

  /// Full repertoire PGN before the add.
  final String previousPgn;

  /// Opening-tree path (prefix) at the position where the move was added.
  final List<String> treePathBeforeAdd;

  /// SAN move that was appended.
  final String moveAdded;
}

/// Serialised writer for PGN + in-memory repertoire updates.
class RepertoireWriter {
  static const int _maxUndoOperations = 20;

  final RepertoireController _controller;
  final RepertoireService _service;

  Future<void> _queueTail = Future.value();
  final List<UndoOperation> _undoStack = [];

  RepertoireWriter(this._controller, {RepertoireService? service})
    : _service = service ?? RepertoireService();

  bool get canUndo => _undoStack.isNotEmpty;

  void clearUndoStack() => _undoStack.clear();

  /// Push an undo snapshot (used internally and by controller for delete ops).
  void pushUndo(UndoOperation operation) {
    _undoStack.add(operation);
    if (_undoStack.length > _maxUndoOperations) {
      _undoStack.removeAt(0);
    }
  }

  Future<T> _serialExec<T>(Future<T> Function() fn) async {
    final result = _queueTail.then((_) => fn());
    _queueTail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Add [san] at [fen] along [pathFromRoot]. No-op if already in repertoire.
  ///
  /// Returns the move path after the add (including [san]).
  Future<List<String>> addMoveAtPosition({
    required String fen,
    required String san,
    required List<String> pathFromRoot,
  }) {
    return _serialExec(() async {
      final tree = _controller.openingTree;
      if (tree != null && tree.hasMove(fen, san)) {
        return [...pathFromRoot, san];
      }

      final previousPgn = _controller.repertoirePgn ?? '';
      final newPath = [...pathFromRoot, san];
      final filePath = _controller.currentRepertoire?.filePath;

      String? updatedPgn;
      if (filePath != null && filePath.isNotEmpty) {
        final result = await _service.appendMoveAtPath(
          filePath,
          pathFromRoot,
          san,
          startingFen: _controller.startingFen,
          isWhiteRepertoire: _controller.isRepertoireWhite,
        );
        if (!result.success) {
          throw StateError('Failed to append move to repertoire PGN');
        }
        updatedPgn = result.updatedContent;
      }

      _controller.appendMoveToExistingLine(
        pathFromRoot,
        san,
        updatedPgnContent: updatedPgn,
      );

      pushUndo(
        UndoOperation(
          previousPgn: previousPgn,
          treePathBeforeAdd: List<String>.from(pathFromRoot),
          moveAdded: san,
        ),
      );

      return newPath;
    });
  }

  /// Reverts the last [addMoveAtPosition] / [acceptSuggestion] add.
  ///
  /// Returns `true` when an operation was undone.
  Future<bool> undo() {
    return _serialExec(() async {
      if (_undoStack.isEmpty) return false;

      final op = _undoStack.removeLast();
      final filePath = _controller.currentRepertoire?.filePath;
      if (filePath != null && filePath.isNotEmpty) {
        await StorageFactory.instance.writeFile(filePath, op.previousPgn);
      }

      await _controller.restoreRepertoireFromPgn(
        op.previousPgn,
        syncPath: op.treePathBeforeAdd,
      );
      return true;
    });
  }

  /// Apply [suggestion.newMoves] after the existing prefix in [suggestion.fullMoves].
  Future<List<String>> acceptSuggestion(SuggestedLine suggestion) async {
    if (suggestion.newMoves.isEmpty) return suggestion.fullMoves;

    final prefixLen = suggestion.fullMoves.length - suggestion.newMoves.length;
    var path = suggestion.fullMoves.sublist(0, prefixLen);
    var fen = _fenAtPath(path);

    for (final san in suggestion.newMoves) {
      path = await addMoveAtPosition(fen: fen, san: san, pathFromRoot: path);
      fen = _fenAtPath(path);
    }
    return path;
  }

  String _fenAtPath(List<String> moves) {
    Position pos;
    final startingFen = _controller.startingFen;
    if (startingFen != null) {
      try {
        pos = Chess.fromSetup(Setup.parseFen(startingFen));
      } catch (_) {
        pos = Chess.initial;
      }
    } else {
      pos = Chess.initial;
    }
    for (final san in moves) {
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
    }
    return pos.fen;
  }
}
