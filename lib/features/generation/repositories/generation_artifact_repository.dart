import '../../documents/models/pgn_document.dart';
import '../models/generation_artifacts.dart';
import '../models/generation_publication.dart';

abstract interface class GenerationArtifactRepository {
  Future<GenerationArtifactSnapshot> read(String path);

  /// Legacy outputs have no source identity. Preview only, never a baseline
  /// for authoritative publication or an automatically resumed build.
  Future<GenerationArtifactSnapshot> readLegacy(String path);

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
