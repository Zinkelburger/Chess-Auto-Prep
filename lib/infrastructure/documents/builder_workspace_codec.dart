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
    'activeKey': snapshot.activeKey,
    'drafts': [
      for (final d in snapshot.drafts)
        {
          'key': d.key,
          'content': d.content,
          'sourcePgn': d.sourcePgn,
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
    if (data['version'] != 1)
      throw const FormatException('Unsupported Builder recovery version');
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
          lineId: raw['lineId'] as String?,
          linePgn: raw['linePgn'] as String?,
          title: raw['title'] as String,
          cursor: cursor,
          label: raw['label'] as String?,
        ),
      );
    }
    final active = data['activeKey'] as String?;
    if (active != null && !keys.contains(active))
      throw const FormatException('Missing active Builder draft');
    return BuilderWorkspaceSnapshot(drafts: drafts, activeKey: active);
  }
}
