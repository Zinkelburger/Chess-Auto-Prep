import '../../features/documents/models/document_save_state.dart';
import '../../features/documents/models/pgn_document.dart';
import '../../features/studies/models/study_workspace_snapshot.dart';

Map<String, Object?> encodeStudyWorkspace(StudyWorkspaceSnapshot value) => {
  'name': value.name,
  'path': value.path,
  'content': value.content,
  'dirty': value.dirty,
  'baseline': _snapshot(value.baseline),
  'uncertain': value.uncertain,
  'uncertainPath': value.uncertainPath,
  'retained': [
    for (final draft in value.retainedDrafts)
      {
        'path': draft.path,
        'content': draft.content,
        'baseline': _snapshot(draft.baseline),
      },
  ],
  'chapter': value.chapter,
  'cursor': value.cursor,
  'flipped': value.flipped,
};
Map<String, Object?>? _snapshot(PgnSnapshot? value) => value == null
    ? null
    : {
        'path': value.path,
        'content': value.content,
        'documentId': value.revision.documentId,
        'nativeIdentity': value.revision.nativeIdentity,
        'sha256': value.revision.sha256,
      };
PgnSnapshot? _decodeSnapshot(Object? raw) {
  if (raw == null) return null;
  final data = raw as Map<String, dynamic>;
  return PgnSnapshot(
    path: data['path'] as String,
    content: data['content'] as String,
    revision: PgnRevision(
      documentId: data['documentId'] as String,
      nativeIdentity: data['nativeIdentity'] as String,
      sha256: data['sha256'] as String,
    ),
  );
}

StudyWorkspaceSnapshot decodeStudyWorkspace(Map<String, dynamic> data) {
  final chapter = data['chapter'] as int;
  final cursor = (data['cursor'] as List).cast<int>();
  if (chapter < 0 || cursor.any((index) => index < 0)) {
    throw const FormatException('Invalid recovery selection');
  }
  final path = data['path'] as String;
  final baseline = _decodeSnapshot(data['baseline']);
  if (baseline != null && baseline.path != path) {
    throw const FormatException('Mismatched recovery baseline');
  }
  return StudyWorkspaceSnapshot(
    name: data['name'] as String,
    path: path,
    content: data['content'] as String,
    dirty: data['dirty'] as bool,
    baseline: baseline,
    uncertain: data['uncertain'] as bool,
    uncertainPath: data['uncertainPath'] as String?,
    retainedDrafts: [
      for (final raw in data['retained'] as List)
        RetainedDocumentDraft(
          path: raw['path'] as String,
          content: raw['content'] as String,
          baseline: _decodeSnapshot(raw['baseline']),
        ),
    ],
    chapter: chapter,
    cursor: cursor,
    flipped: data['flipped'] as bool,
  );
}
