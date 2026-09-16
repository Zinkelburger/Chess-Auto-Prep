import '../models/repertoire_creation.dart';
import '../models/repertoire_metadata.dart';

/// Domain boundary for the repertoire catalog. No filesystem or widget types.
abstract interface class RepertoireCatalogRepository {
  Future<List<RepertoireMetadata>> listRepertoires();
  Future<List<RepertoireMetadata>> listStudies();
  Future<RepertoireCreationResult> create(CreateRepertoire request);
  Future<void> rename(RepertoireMetadata repertoire, String name);

  /// Retains the repertoire's files in recovery storage.
  Future<void> moveToRecovery(RepertoireMetadata repertoire);
}
