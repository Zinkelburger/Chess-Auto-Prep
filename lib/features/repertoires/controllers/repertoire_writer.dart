/// Serialized repertoire mutations and storage-derived undo history.
library;

import 'package:chess_auto_prep/chess_core/pgn/repertoire_document_mutation.dart';

import 'package:dartchess/dartchess.dart';

import '../repositories/repertoire_document_repository.dart';
import '../models/repertoire_mutation_receipt.dart';
import '../../documents/models/pgn_document.dart';
import '../../../utils/atomic_file.dart';
import '../../../utils/chess_utils.dart' show playSanOrNullMove, tryParseFen;
import 'repertoire_document_session.dart';
import 'repertoire_board_controller.dart';

sealed class _UndoEntry {}

/// Immutable provenance is separate from the expectation advanced by undo.
class _SavedUndo extends _UndoEntry {
  _SavedUndo({
    required this.before,
    required this.after,
    required this.path,
    required this.filePath,
    required this.id,
    required this.predecessorId,
    required this.provenance,
  });

  final String before;
  final String after;
  final List<String> path;
  final String? filePath;
  final int id;
  final int? predecessorId;

  /// Null only for an in-memory document. Every batch step shares the actual
  /// immutable native receipt; intermediate logical states invent no revision.
  final RepertoireMutationReceipt? provenance;
  PgnSnapshot? expectedNative;
  String? expectedMemoryContent;
}

/// A scratch-tree edit never authorizes replacing a file-backed document.
class _DraftUndo extends _UndoEntry {
  _DraftUndo(this.isCurrent, this.restore);
  final bool Function() isCurrent;
  final void Function() restore;
}

class RepertoireWriter {
  RepertoireWriter({
    required this.document,
    required this.board,
    required this.documents,
  });

  static const int _maxUndoOperations = 20;
  final RepertoireDocumentSession document;
  final RepertoireBoardController board;
  final RepertoireDocumentRepository documents;
  final List<_UndoEntry> _undoStack = [];
  int _session = 0;
  int _nextUndoId = 0;

  bool get canUndo => _undoStack.isNotEmpty;

  /// Suspend queued writes during a load without losing recoverable history.
  void invalidatePendingActions() => _session++;

  void clearUndoStack() {
    _session++;
    _undoStack.clear();
  }

  void recordDraftUndo({
    required bool Function() isCurrent,
    required void Function() restore,
  }) => _push(_DraftUndo(isCurrent, restore));

  void _push(_UndoEntry entry) {
    _undoStack.add(entry);
    if (_undoStack.length > _maxUndoOperations) _undoStack.removeAt(0);
  }

  Future<T> _serialExec<T>(Future<T> Function() fn) =>
      document.runDocumentMutation(fn);

  /// Invocations capture the document session before joining the queue.
  /// A load/reset invalidates queued actions, even for an A -> B -> A switch.
  Future<List<String>> addMoveAtPosition({
    required String fen,
    required String san,
    required List<String> pathFromRoot,
  }) => addMovesAtPosition(pathFromRoot: pathFromRoot, sans: [san]);

  Future<List<String>> addMovesAtPosition({
    required List<String> pathFromRoot,
    required List<String> sans,
  }) {
    final prefix = List<String>.unmodifiable(pathFromRoot);
    final moves = List<String>.unmodifiable(sans);
    final session = _session;
    final filePath = _filePath;
    final startingFen = board.startingFen;
    final isWhite = document.isRepertoireWhite;
    return _serialExec(() async {
      _requireSession(session);
      if (moves.isEmpty) return List<String>.of(prefix);
      // Keep the repertoire's existing transposition semantics: moves already
      // known at this position are no-ops, even through another SAN path.
      var position = _positionAtPath(prefix);
      var firstNew = 0;
      while (firstNew < moves.length &&
          (document.openingGraph?.hasMove(position.fen, moves[firstNew]) ??
              false)) {
        final next = playSanOrNullMove(position, moves[firstNew]);
        if (next == null) break;
        position = next;
        firstNew++;
      }
      if (firstNew == moves.length) return [...prefix, ...moves];
      final appendPrefix = [...prefix, ...moves.take(firstNew)];
      final newMoves = moves.sublist(firstNew);
      final nativeReceipt = filePath == null
          ? null
          : await documents.append(
              filePath,
              appendPrefix,
              newMoves,
              startingFen: startingFen,
              isWhiteRepertoire: isWhite,
            );
      nativeReceipt?.validate(
        path: filePath!,
        requestedPath: [...prefix, ...moves],
      );
      final result =
          nativeReceipt?.mutation ??
          prepareAppendMoves(
            document.repertoirePgn ?? '',
            appendPrefix,
            newMoves,
            startingFen: startingFen,
            isWhiteRepertoire: isWhite,
          );
      // The adapter already validates before commit. Defensively reject broken
      // receipts here without inventing undo from stale controller memory.
      result.validate(requestedPath: [...prefix, ...moves]);
      _requireSession(session);
      _acceptReceipt(result, filePath, nativeReceipt);
      if (result.previousContent == document.repertoirePgn) {
        // Preserve the existing incremental presentation path when the
        // session really owns the validated baseline. External changes need
        // a full refresh so their annotations/games also reach the UI.
        for (final step in result.steps) {
          if (session != _session) break;
          document.appendMoveToExistingLine(
            step.pathBefore,
            step.san,
            updatedPgnContent: step.content,
          );
        }
      } else {
        await document.restoreRepertoireFromPgn(
          result.updatedContent,
          syncPath: board.currentMoveSequence,
        );
      }
      _requireSession(session);
      return [...prefix, ...moves];
    });
  }

  String? get _filePath {
    final path = document.currentRepertoire?.filePath;
    return path == null || path.isEmpty ? null : path;
  }

  void _requireSession(int session) {
    if (session != _session || document.isLoading) {
      throw StateError('The repertoire changed before the action could run.');
    }
  }

  void _acceptReceipt(
    RepertoireAppendPlan receipt,
    String? filePath,
    RepertoireMutationReceipt? provenance,
  ) {
    if (receipt.steps.isEmpty) return;
    final head = _undoStack.lastOrNull;
    int? predecessorId;
    if (head is _SavedUndo &&
        head.filePath == filePath &&
        head.after == receipt.previousContent &&
        (provenance == null
            ? head.provenance == null &&
                  head.expectedMemoryContent == receipt.previousContent
            : head.expectedNative?.revision == provenance.before.revision &&
                  head.expectedNative?.content == provenance.before.content)) {
      predecessorId = head.id;
    }
    // An unrelated edit breaks the chain permanently. Even a later undo
    // restoring equal-looking content must not re-arm the old history.
    if (head is _SavedUndo) {
      head.expectedNative = null;
      head.expectedMemoryContent = null;
    }
    var before = receipt.previousContent;
    for (final step in receipt.steps) {
      final entry = _SavedUndo(
        before: before,
        after: step.content,
        path: step.pathBefore,
        filePath: filePath,
        id: _nextUndoId++,
        predecessorId: predecessorId,
        provenance: provenance,
      );
      _push(entry);
      predecessorId = entry.id;
      before = step.content;
    }
    final top = _undoStack.last as _SavedUndo;
    if (provenance == null) {
      top.expectedMemoryContent = receipt.updatedContent;
    } else {
      top.expectedNative = provenance.after;
    }
  }

  /// Only a confirmed commit consumes history. Failures and conflicts retain
  /// the entry; the compare-and-swap never uses freshly read arbitrary content
  /// to refresh an old entry's expectation.
  Future<bool> undo() {
    final session = _session;
    return _serialExec(() async {
      _requireSession(session);
      if (_undoStack.isEmpty) return false;
      final entry = _undoStack.last;
      if (entry is _DraftUndo) {
        if (!entry.isCurrent()) {
          throw StateError(
            'The draft changed after this edit; undo is unavailable.',
          );
        }
        entry.restore();
        _undoStack.removeLast();
        return true;
      }
      final op = entry as _SavedUndo;
      PgnSnapshot? restored;
      final filePath = op.filePath;
      if (filePath != null) {
        final expected = op.expectedNative;
        if (expected == null) throw AtomicWriteConflict(filePath);
        restored = await documents.restore(expected, op.before);
      } else {
        final expected = op.expectedMemoryContent;
        if (expected == null || document.repertoirePgn != expected) {
          throw const AtomicWriteConflict('draft');
        }
      }
      if (session != _session) return true;
      if (!identical(_undoStack.lastOrNull, op)) {
        // A synchronous scratch edit arrived while storage was committing.
        // Consume only this confirmed undo and preserve the newer draft.
        _undoStack.remove(op);
        return true;
      }
      _undoStack.removeLast();
      final predecessor = _undoStack.lastOrNull;
      if (predecessor is _SavedUndo &&
          predecessor.id == op.predecessorId &&
          predecessor.after == op.before) {
        if (filePath == null) {
          predecessor.expectedMemoryContent = op.before;
        } else {
          predecessor.expectedNative = restored;
        }
      }
      // Publish history before refreshing UI: a failed refresh must never
      // replay an already committed undo on retry.
      await document.restoreRepertoireFromPgn(op.before, syncPath: op.path);
      return true;
    });
  }

  Position _positionAtPath(List<String> moves) {
    final start = board.startingFen;
    var position = start == null
        ? Chess.initial
        : tryParseFen(start) ?? Chess.initial;
    for (final san in moves) {
      final next = playSanOrNullMove(position, san);
      if (next == null) break;
      position = next;
    }
    return position;
  }
}
