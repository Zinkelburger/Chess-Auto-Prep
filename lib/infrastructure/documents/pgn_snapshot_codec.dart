import '../../features/documents/models/pgn_document.dart';

Map<String, Object?>? encodePgnSnapshot(PgnSnapshot? value) => value == null
    ? null
    : {
        'path': value.path,
        'content': value.content,
        'documentId': value.revision.documentId,
        'nativeIdentity': value.revision.nativeIdentity,
        'sha256': value.revision.sha256,
      };
PgnSnapshot? decodePgnSnapshot(Object? raw) {
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
