/// Atomic repertoire mutations (one-click browse add, suggestion accept).
library;

import 'package:dartchess/dartchess.dart';

import '../features/coverage/services/coverage_suggestion_service.dart';
import '../services/repertoire_service.dart';
import '../services/storage/storage_factory.dart';
import '../utils/chess_utils.dart' show playSanOrNullMove, tryParseFen;
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

  /// Add [sans] one after another at the end of [pathFromRoot], skipping the
  /// leading plies the repertoire already has.  The plies that are new are
  /// written to disk in **one** read/lex/write ([RepertoireService
  /// .appendMovesAtPath]) instead of one per ply, then folded into the
  /// in-memory lines and tree.
  ///
  /// Returns the move path after the add (the full line).  Undo history is
  /// still one entry per ply — the service hands back the document as it
  /// stood after each — so undoing a suggestion peels moves off one at a
  /// time, as it always has.
  Future<List<String>> addMovesAtPosition({
    required List<String> pathFromRoot,
    required List<String> sans,
  }) {
    if (sans.isEmpty) return Future.value(List<String>.from(pathFromRoot));
    return _serialExec(() async {
      final tree = _controller.openingTree;
      var position = _positionAtPath(pathFromRoot);
      var path = List<String>.from(pathFromRoot);

      // Skip the prefix that is already book; the first unknown ply and
      // everything after it is what gets written.
      var firstNew = 0;
      while (firstNew < sans.length &&
          tree != null &&
          tree.hasMove(position.fen, sans[firstNew])) {
        final next = playSanOrNullMove(position, sans[firstNew]);
        if (next == null) break;
        position = next;
        path.add(sans[firstNew]);
        firstNew++;
      }
      final newSans = sans.sublist(firstNew);
      if (newSans.isEmpty) return path;

      final previousPgn = _controller.repertoirePgn ?? '';
      final prefix = List<String>.from(path);
      final filePath = _controller.currentRepertoire?.filePath;

      String? updatedPgn;
      var snapshots = const <String>[];
      if (filePath != null && filePath.isNotEmpty) {
        final result = await _service.appendMovesAtPath(
          filePath,
          prefix,
          newSans,
          startingFen: _controller.startingFen,
          isWhiteRepertoire: _controller.isRepertoireWhite,
        );
        if (!result.success) {
          throw StateError('Failed to append moves to repertoire PGN');
        }
        updatedPgn = result.updatedContent;
        snapshots = result.snapshots;
      }

      // The controller extends its lines and tree one ply at a time; the
      // file content is handed over with the last ply, once the in-memory
      // line already holds the earlier ones, so the two stay consistent.
      for (var i = 0; i < newSans.length; i++) {
        // Snapshots only exist for a file-backed repertoire; an in-memory one
        // has no per-ply document, so every ply undoes to the state before
        // the whole add — which is what one-ply-at-a-time adds recorded too.
        // The bound is checked rather than assumed: a short snapshot list
        // must degrade to that same fallback, not throw mid-add.
        final snapshot = i > 0 && i - 1 < snapshots.length
            ? snapshots[i - 1]
            : previousPgn;
        pushUndo(
          UndoOperation(
            previousPgn: snapshot,
            treePathBeforeAdd: List<String>.from(path),
            moveAdded: newSans[i],
          ),
        );
        _controller.appendMoveToExistingLine(
          path,
          newSans[i],
          updatedPgnContent: i == newSans.length - 1 ? updatedPgn : null,
        );
        path = [...path, newSans[i]];
      }

      return path;
    });
  }

  /// Apply [suggestion.newMoves] after the existing prefix in [suggestion.fullMoves].
  Future<List<String>> acceptSuggestion(SuggestedLine suggestion) {
    if (suggestion.newMoves.isEmpty) return Future.value(suggestion.fullMoves);
    final prefixLen = suggestion.fullMoves.length - suggestion.newMoves.length;
    return addMovesAtPosition(
      pathFromRoot: suggestion.fullMoves.sublist(0, prefixLen),
      sans: suggestion.newMoves,
    );
  }

  /// The board after [moves] from the repertoire's start position, replayed
  /// once; an illegal move ends the replay where it stands.
  Position _positionAtPath(List<String> moves) {
    final startingFen = _controller.startingFen;
    var pos = startingFen == null
        ? Chess.initial
        : tryParseFen(startingFen) ?? Chess.initial;
    for (final san in moves) {
      final next = playSanOrNullMove(pos, san);
      if (next == null) break;
      pos = next;
    }
    return pos;
  }
}
