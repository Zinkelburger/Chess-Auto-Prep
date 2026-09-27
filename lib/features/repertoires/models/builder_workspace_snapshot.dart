import '../../documents/models/pgn_document.dart';
import 'repertoire_metadata.dart';

/// An unsaved editable tree, including its original file precondition. Recovery
/// never treats this copy as authority to overwrite a subsequently changed file.
class BuilderDraft {
  BuilderDraft({
    required this.key,
    required this.repertoire,
    required this.content,
    required this.sourcePgn,
    this.sourceRevision,
    required this.lineId,
    required this.linePgn,
    required this.title,
    required List<int> cursor,
    this.label,
  }) : cursor = List.unmodifiable(cursor);
  final String key;
  final RepertoireMetadata? repertoire;
  final String content;
  final String? sourcePgn;
  final PgnRevision? sourceRevision;
  final String? lineId;
  final String? linePgn;
  final String title;
  final List<int> cursor;
  final String? label;
  BuilderDraft withKey(String value) => BuilderDraft(
    key: value,
    repertoire: repertoire,
    content: content,
    sourcePgn: sourcePgn,
    sourceRevision: sourceRevision,
    lineId: lineId,
    linePgn: linePgn,
    title: title,
    cursor: cursor,
    label: label,
  );
}

class BuilderCopyUncertainty {
  const BuilderCopyUncertainty({
    required this.draftKey,
    required this.destination,
    required this.content,
    required this.outcome,
  });
  final String draftKey;
  final String destination;
  final String content;
  final PgnWriteUncertain outcome;
  BuilderCopyUncertainty withKey(String value) => BuilderCopyUncertainty(
    draftKey: value,
    destination: destination,
    content: content,
    outcome: outcome,
  );
}

class BuilderWorkspaceSnapshot {
  BuilderWorkspaceSnapshot({
    required List<BuilderDraft> drafts,
    required this.activeKey,
    List<BuilderCopyUncertainty> uncertainCopies = const [],
  }) : drafts = List.unmodifiable(drafts),
       uncertainCopies = List.unmodifiable(uncertainCopies);
  final List<BuilderDraft> drafts;
  final String? activeKey;
  final List<BuilderCopyUncertainty> uncertainCopies;
  bool get needsRecovery => drafts.isNotEmpty || uncertainCopies.isNotEmpty;
}
