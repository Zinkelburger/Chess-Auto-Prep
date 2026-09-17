import 'repertoire_metadata.dart';

/// An unsaved editable tree, including its original file precondition. Recovery
/// never treats this copy as authority to overwrite a subsequently changed file.
class BuilderDraft {
  BuilderDraft({
    required this.key,
    required this.repertoire,
    required this.content,
    required this.sourcePgn,
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
    lineId: lineId,
    linePgn: linePgn,
    title: title,
    cursor: cursor,
    label: label,
  );
}

class BuilderWorkspaceSnapshot {
  BuilderWorkspaceSnapshot({
    required List<BuilderDraft> drafts,
    required this.activeKey,
  }) : drafts = List.unmodifiable(drafts);
  final List<BuilderDraft> drafts;
  final String? activeKey;
  bool get needsRecovery => drafts.isNotEmpty;
}
