import '../../features/documents/models/document_save_state.dart';
import '../../features/documents/models/pgn_workspace_snapshot.dart';
import 'pgn_snapshot_codec.dart';
import 'workspace_recovery_codec.dart';

class PgnWorkspaceCodec
    implements WorkspaceRecoveryCodec<PgnWorkspaceSnapshot> {
  const PgnWorkspaceCodec();
  @override
  bool needsRecovery(PgnWorkspaceSnapshot snapshot) => snapshot.needsRecovery;
  @override
  Map<String, Object?> encode(PgnWorkspaceSnapshot snapshot) => {
    'path': snapshot.path,
    'content': snapshot.content,
    'dirty': snapshot.dirty,
    'persistedGames': snapshot.persistedGames,
    'baseline': encodePgnSnapshot(snapshot.baseline),
    'wholeReplacement': snapshot.wholeReplacement,
    'uncertain': snapshot.uncertain,
    'uncertainPath': snapshot.uncertainPath,
    'retained': [
      for (final draft in snapshot.retainedDrafts)
        {
          'path': draft.path,
          'content': draft.content,
          'baseline': encodePgnSnapshot(draft.baseline),
        },
    ],
    'gameIndex': snapshot.gameIndex,
    'ply': snapshot.ply,
    'flipped': snapshot.flipped,
  };
  @override
  PgnWorkspaceSnapshot decode(Map<String, dynamic> data) {
    final path = data['path'] as String;
    final baseline = decodePgnSnapshot(data['baseline']);
    final originals = (data['persistedGames'] as List).cast<String>();
    final gameIndex = data['gameIndex'] as int;
    final ply = data['ply'] as int;
    if ((baseline != null && baseline.path != path) ||
        gameIndex < 0 ||
        (originals.isNotEmpty && gameIndex >= originals.length) ||
        ply < 0) {
      throw const FormatException('Invalid PGN recovery selection or baseline');
    }
    return PgnWorkspaceSnapshot(
      path: path,
      content: data['content'] as String,
      dirty: data['dirty'] as bool,
      persistedGames: originals,
      baseline: baseline,
      wholeReplacement: data['wholeReplacement'] as bool,
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
      gameIndex: gameIndex,
      ply: ply,
      flipped: data['flipped'] as bool,
    );
  }
}
