import '../../documents/models/pgn_document.dart';
import '../models/generation_artifacts.dart';
import '../models/generation_recovery.dart';
import '../models/generation_publication.dart';

abstract interface class GenerationArtifactRepository {
  Future<GenerationArtifactSnapshot> read(String path);

  /// Read-only recovery over retained proposals/history and legacy sidecars.
  /// None of these observations can select a generation or authorize resume.
  Future<GenerationRecoverySources> listRecoverySources();
  Future<GenerationRecoveryCatalog> listRecovery(String path);
  Future<GenerationRecoverySnapshot> readRecovery(
    GenerationRecoveryEntry entry,
  );

  /// Export captured bytes to an exclusively created destination.
  Future<void> exportRecovery(GenerationRecoveryFile file, String destination);

  Future<GenerationArtifactRun> begin(
    String path,
    Map<String, dynamic> config, {
    GenerationSource? source,
    String? expectedGenerationId,
  });
  Future<GenerationArtifactProposal> prepare(
    GenerationArtifactRun run,
    Map<GenerationArtifactKind, String?> changes,
  );
  Future<void> select(
    GenerationArtifactRun run,
    GenerationArtifactProposal proposal, {
    PgnSnapshot? publishedSource,
  });
  void close(GenerationArtifactRun run);
}
