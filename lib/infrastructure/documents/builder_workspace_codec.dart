import '../../features/documents/models/pgn_document.dart';
import 'pgn_snapshot_codec.dart';
import '../../features/repertoires/models/builder_workspace_snapshot.dart';
import '../../features/repertoires/models/repertoire_metadata.dart';
import 'workspace_recovery_codec.dart';

class BuilderWorkspaceCodec
    implements WorkspaceRecoveryCodec<BuilderWorkspaceSnapshot> {
  const BuilderWorkspaceCodec();
  @override
  bool needsRecovery(BuilderWorkspaceSnapshot snapshot) =>
      snapshot.needsRecovery;
  @override
  Map<String, Object?> encode(BuilderWorkspaceSnapshot snapshot) => {
    'version': 1,
    'copies': [
      for (final copy in snapshot.uncertainCopies)
        {
          'draftKey': copy.draftKey,
          'destination': copy.destination,
          'content': copy.content,
          'error': copy.outcome.error.toString(),
          'before': encodePgnSnapshot(copy.outcome.before),
          'observed': encodePgnSnapshot(copy.outcome.observed),
          'recoveryPath': copy.outcome.recoveryPath,
          'installed': copy.outcome.installedRevision == null
              ? null
              : {
                  'documentId': copy.outcome.installedRevision!.documentId,
                  'nativeIdentity':
                      copy.outcome.installedRevision!.nativeIdentity,
                  'sha256': copy.outcome.installedRevision!.sha256,
                },
        },
    ],
    'activeKey': snapshot.activeKey,
    'drafts': [
      for (final d in snapshot.drafts)
        {
          'key': d.key,
          'content': d.content,
          'sourcePgn': d.sourcePgn,
          'sourceRevision': d.sourceRevision == null
              ? null
              : {
                  'documentId': d.sourceRevision!.documentId,
                  'nativeIdentity': d.sourceRevision!.nativeIdentity,
                  'sha256': d.sourceRevision!.sha256,
                },
          'lineId': d.lineId,
          'linePgn': d.linePgn,
          'title': d.title,
          'cursor': d.cursor,
          'label': d.label,
          'repertoire': d.repertoire == null
              ? null
              : {
                  'path': d.repertoire!.filePath,
                  'name': d.repertoire!.name,
                  'count': d.repertoire!.gameCount,
                  'modified': d.repertoire!.lastModified.toIso8601String(),
                },
        },
    ],
  };
  @override
  BuilderWorkspaceSnapshot decode(Map<String, dynamic> data) {
    if (data['version'] != 1) {
      throw const FormatException('Unsupported Builder recovery version');
    }
    final drafts = <BuilderDraft>[];
    final keys = <String>{};
    for (final raw in data['drafts'] as List) {
      final r = raw['repertoire'];
      final cursor = (raw['cursor'] as List).cast<int>();
      final key = raw['key'] as String;
      if (!keys.add(key) || cursor.any((index) => index < 0)) {
        throw const FormatException('Invalid Builder recovery selection');
      }
      drafts.add(
        BuilderDraft(
          key: key,
          repertoire: r == null
              ? null
              : RepertoireMetadata(
                  filePath: r['path'] as String,
                  name: r['name'] as String,
                  gameCount: r['count'] as int,
                  lastModified: DateTime.parse(r['modified'] as String),
                ),
          content: raw['content'] as String,
          sourcePgn: raw['sourcePgn'] as String?,
          sourceRevision: raw['sourceRevision'] == null
              ? null
              : PgnRevision(
                  documentId: raw['sourceRevision']['documentId'] as String,
                  nativeIdentity:
                      raw['sourceRevision']['nativeIdentity'] as String,
                  sha256: raw['sourceRevision']['sha256'] as String,
                ),
          lineId: raw['lineId'] as String?,
          linePgn: raw['linePgn'] as String?,
          title: raw['title'] as String,
          cursor: cursor,
          label: raw['label'] as String?,
        ),
      );
    }
    final active = data['activeKey'] as String?;
    if (active != null && !keys.contains(active)) {
      throw const FormatException('Missing active Builder draft');
    }
    final copies = <BuilderCopyUncertainty>[];
    for (final copy in (data['copies'] as List? ?? const [])) {
      if (!keys.contains(copy['draftKey'])) {
        throw const FormatException('Missing uncertain Builder copy draft');
      }
      final installed = copy['installed'];
      copies.add(
        BuilderCopyUncertainty(
          draftKey: copy['draftKey'] as String,
          destination: copy['destination'] as String,
          content: copy['content'] as String,
          outcome: PgnWriteUncertain(
            error: copy['error'] as String,
            before: decodePgnSnapshot(copy['before']),
            observed: decodePgnSnapshot(copy['observed']),
            recoveryPath: copy['recoveryPath'] as String?,
            installedRevision: installed == null
                ? null
                : PgnRevision(
                    documentId: installed['documentId'] as String,
                    nativeIdentity: installed['nativeIdentity'] as String,
                    sha256: installed['sha256'] as String,
                  ),
          ),
        ),
      );
    }
    return BuilderWorkspaceSnapshot(
      drafts: drafts,
      activeKey: active,
      uncertainCopies: copies,
    );
  }
}
