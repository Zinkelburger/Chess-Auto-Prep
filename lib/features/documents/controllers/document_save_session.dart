import 'dart:async';

import '../models/document_save_state.dart';
import '../models/pgn_document.dart';
import '../repositories/pgn_document_store.dart';

/// A document's save owner, independent of widgets, providers and filesystem.
/// Edits remain allowed during I/O; the receipt advances only the submitted
/// baseline, and later edits remain dirty. No failed operation is replayed.
class DocumentSaveSession {
  DocumentSaveSession.opened(this._store, PgnSnapshot snapshot)
    : _state = DocumentSaveState(
        path: snapshot.path,
        content: snapshot.content,
        baseline: snapshot,
        phase: DocumentSavePhase.clean,
      );
  DocumentSaveSession.draft(
    this._store, {
    required String path,
    required String content,
  }) : _state = DocumentSaveState(
         path: path,
         content: content,
         phase: DocumentSavePhase.dirty,
       );

  final PgnDocumentStore _store;
  final _changes = StreamController<DocumentSaveState>.broadcast(sync: true);
  DocumentSaveState _state;
  bool _disposed = false;
  DocumentSaveState get state => _state;
  Stream<DocumentSaveState> get changes => _changes.stream;

  void _publish(DocumentSaveState next) {
    _state = next;
    if (!_disposed) _changes.add(next);
  }

  void edit(String content) {
    if (_disposed || content == state.content) return;
    _publish(
      DocumentSaveState(
        path: state.path,
        content: content,
        baseline: state.baseline,
        phase: state.busy || state.outcome != null
            ? state.phase
            : content == state.baseline?.content
            ? DocumentSavePhase.clean
            : DocumentSavePhase.dirty,
        outcome: state.outcome,
        uncertainPath: state.uncertainPath,
        readFailure: state.readFailure,
        retainedDrafts: state.retainedDrafts,
      ),
    );
  }

  /// Dismiss presentation only. The captured revision and an uncertain write
  /// remain intact, so dismissal cannot authorize replacement or retry.
  void keepEditing() {
    if (_disposed || state.busy) return;
    _publish(
      DocumentSaveState(
        path: state.path,
        content: state.content,
        baseline: state.baseline,
        phase: state.uncertain
            ? DocumentSavePhase.uncertain
            : state.dirty
            ? DocumentSavePhase.dirty
            : DocumentSavePhase.clean,
        outcome: state.uncertain ? state.outcome : null,
        uncertainPath: state.uncertainPath,
        retainedDrafts: state.retainedDrafts,
      ),
    );
  }

  Future<PgnWriteResult?> save() async {
    if (_disposed || !state.canSave) return null;
    return _write(state.path, copy: false);
  }

  /// A successful copy becomes this session's document. The original is never
  /// replaced. Failed/colliding copies retain the original path and baseline.
  Future<PgnWriteResult?> saveCopy(String destination) async {
    if (_disposed || state.busy) return null;
    return _write(destination, copy: true);
  }

  Future<PgnWriteResult> _write(
    String destination, {
    required bool copy,
  }) async {
    final submitted = state;
    _publish(
      DocumentSaveState(
        path: state.path,
        content: state.content,
        baseline: state.baseline,
        phase: DocumentSavePhase.saving,
        outcome: state.outcome,
        uncertainPath: state.uncertainPath,
        retainedDrafts: state.retainedDrafts,
      ),
    );
    PgnWriteResult result;
    try {
      result = copy || submitted.baseline == null
          ? await _store.create(destination, submitted.content)
          : await _store.save(submitted.baseline!, submitted.content);
    } catch (error) {
      // An adapter violating the typed-outcome contract cannot prove whether
      // it wrote. Preserve the draft and require reconciliation, not a retry.
      result = PgnWriteUncertain(
        error: error,
        before: submitted.baseline,
        observed: null,
      );
    }
    if (result is PgnSaved) {
      _publish(
        DocumentSaveState(
          path: result.after.path,
          content: state.content,
          baseline: result.after,
          phase: state.content == result.after.content
              ? DocumentSavePhase.saved
              : DocumentSavePhase.dirty,
          retainedDrafts: state.retainedDrafts,
        ),
      );
    } else {
      // A failed copy must not erase an unresolved original uncertain write.
      final outcome = submitted.uncertain && result is! PgnWriteUncertain
          ? submitted.outcome!
          : result;
      _publish(
        DocumentSaveState(
          path: state.path,
          content: state.content,
          baseline: state.baseline,
          phase: switch (outcome) {
            PgnConflict() => DocumentSavePhase.conflict,
            PgnNameCollision() => DocumentSavePhase.collision,
            PgnWriteUncertain() => DocumentSavePhase.uncertain,
            _ => DocumentSavePhase.failed,
          },
          outcome: outcome,
          uncertainPath: result is PgnWriteUncertain
              ? destination
              : submitted.uncertainPath,
          retainedDrafts: state.retainedDrafts,
        ),
      );
    }
    return result;
  }

  /// Read-only inspection never adopts a newer revision or clears dirty state.
  Future<PgnOpenResult> inspectCurrent() async {
    try {
      return await _store.open(state.inspectionPath);
    } catch (error) {
      return PgnReadFailed(error);
    }
  }

  /// Explicit reload always reads again; a prior conflict snapshot may already
  /// be stale. Preserve the latest draft (including edits during the read).
  Future<void> reloadPreservingDraft() async {
    if (_disposed || state.busy) return;
    final previous = state;
    _publish(
      DocumentSaveState(
        path: state.path,
        content: state.content,
        baseline: state.baseline,
        phase: DocumentSavePhase.reloading,
        outcome: state.outcome,
        uncertainPath: state.uncertainPath,
        retainedDrafts: state.retainedDrafts,
      ),
    );
    final result = await inspectCurrent();
    if (result is PgnOpened) {
      final retained = [...state.retainedDrafts];
      if (state.dirty || state.uncertain) {
        retained.add(
          RetainedDocumentDraft(
            path: state.path,
            content: state.content,
            baseline: state.baseline,
          ),
        );
      }
      _publish(
        DocumentSaveState(
          path: result.snapshot.path,
          content: result.snapshot.content,
          baseline: result.snapshot,
          phase: DocumentSavePhase.clean,
          retainedDrafts: retained,
        ),
      );
    } else {
      _publish(
        DocumentSaveState(
          path: state.path,
          content: state.content,
          baseline: state.baseline,
          phase: previous.outcome != null
              ? previous.phase
              : state.dirty
              ? DocumentSavePhase.dirty
              : DocumentSavePhase.clean,
          outcome: previous.outcome,
          uncertainPath: previous.uncertainPath,
          readFailure: result,
          retainedDrafts: state.retainedDrafts,
        ),
      );
    }
  }

  /// Restores text as an unsaved draft against the currently loaded revision.
  /// Restoring itself never writes; any subsequent save still validates it.
  void restoreDraft(int index) {
    if (_disposed || state.busy) return;
    final retained = [...state.retainedDrafts];
    final draft = retained.removeAt(index);
    if (state.dirty) {
      retained.add(
        RetainedDocumentDraft(
          path: state.path,
          content: state.content,
          baseline: state.baseline,
        ),
      );
    }
    _publish(
      DocumentSaveState(
        path: state.path,
        content: draft.content,
        baseline: state.baseline,
        phase: state.uncertain
            ? DocumentSavePhase.uncertain
            : draft.content == state.baseline?.content
            ? DocumentSavePhase.clean
            : DocumentSavePhase.dirty,
        outcome: state.uncertain ? state.outcome : null,
        uncertainPath: state.uncertainPath,
        retainedDrafts: retained,
      ),
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    await _changes.close();
  }
}
