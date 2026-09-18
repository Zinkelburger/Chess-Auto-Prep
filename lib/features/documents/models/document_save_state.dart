import 'pgn_document.dart';

enum DocumentSavePhase {
  clean,
  dirty,
  saving,
  saved,
  conflict,
  collision,
  failed,
  uncertain,
  reloading,
}

/// An explicitly retained draft. The workspace owns checkpoint persistence;
/// constructing this value alone does not make its contents durable.
class RetainedDocumentDraft {
  const RetainedDocumentDraft({
    required this.path,
    required this.content,
    required this.baseline,
  });
  final String path;
  final String content;
  final PgnSnapshot? baseline;
}

class DocumentSaveState {
  DocumentSaveState({
    required this.path,
    required this.content,
    required this.phase,
    this.baseline,
    this.outcome,
    this.readFailure,
    this.uncertainPath,
    this.pendingEdits = false,
    this.dirtyOverride,
    List<RetainedDocumentDraft> retainedDrafts = const [],
  }) : retainedDrafts = List.unmodifiable(retainedDrafts);
  final String path;

  /// Last serialized editor content; structured editors may have newer edits.
  final String content;
  final bool pendingEdits;

  /// Scoped editors compare per-game baselines instead of whole-document text.
  /// Their edit owner supplies this without serializing the collection for UI.
  final bool? dirtyOverride;
  final PgnSnapshot? baseline;
  final DocumentSavePhase phase;
  final PgnWriteResult? outcome;
  final PgnOpenResult? readFailure;
  final String? uncertainPath;
  String get inspectionPath => uncertainPath ?? path;
  final List<RetainedDocumentDraft> retainedDrafts;
  bool get busy =>
      phase == DocumentSavePhase.saving || phase == DocumentSavePhase.reloading;
  bool get dirty =>
      dirtyOverride ??
      (pendingEdits || baseline == null || content != baseline!.content);
  bool get uncertain => outcome is PgnWriteUncertain;
  bool get needsResolution =>
      dirty || uncertain || busy || retainedDrafts.isNotEmpty;
  bool get canSave => path.isNotEmpty && !busy && !uncertain && dirty;
}
