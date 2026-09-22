import '../../features/documents/models/document_save_state.dart';
import '../documents/pgn_snapshot_codec.dart';
import '../../features/studies/models/study_workspace_snapshot.dart';
import '../documents/workspace_recovery_codec.dart';

class StudyRecoveryCodec
    implements WorkspaceRecoveryCodec<StudyWorkspaceSnapshot> {
  const StudyRecoveryCodec();
  @override
  Map<String, Object?> encode(StudyWorkspaceSnapshot snapshot) =>
      encodeStudyWorkspace(snapshot);
  @override
  StudyWorkspaceSnapshot decode(Map<String, dynamic> data) =>
      decodeStudyWorkspace(data);
  @override
  bool needsRecovery(StudyWorkspaceSnapshot snapshot) => snapshot.needsRecovery;
}

Map<String, Object?> encodeStudyWorkspace(StudyWorkspaceSnapshot value) => {
  'name': value.name,
  'path': value.path,
  'content': value.content,
  'dirty': value.dirty,
  'baseline': encodePgnSnapshot(value.baseline),
  'uncertain': value.uncertain,
  'uncertainPath': value.uncertainPath,
  'retained': [
    for (final draft in value.retainedDrafts)
      {
        'path': draft.path,
        'content': draft.content,
        'baseline': encodePgnSnapshot(draft.baseline),
      },
  ],
  'chapter': value.chapter,
  'cursor': value.cursor,
  'flipped': value.flipped,
};

StudyWorkspaceSnapshot decodeStudyWorkspace(Map<String, dynamic> data) {
  final chapter = data['chapter'] as int;
  final cursor = (data['cursor'] as List).cast<int>();
  if (chapter < 0 || cursor.any((index) => index < 0)) {
    throw const FormatException('Invalid recovery selection');
  }
  final path = data['path'] as String;
  final baseline = decodePgnSnapshot(data['baseline']);
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
          baseline: decodePgnSnapshot(raw['baseline']),
        ),
    ],
    chapter: chapter,
    cursor: cursor,
    flipped: data['flipped'] as bool,
  );
}
