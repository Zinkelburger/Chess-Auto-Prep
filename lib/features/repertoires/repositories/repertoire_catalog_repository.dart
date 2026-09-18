import '../models/repertoire_creation.dart';
import '../models/repertoire_metadata.dart';
import '../models/repertoire_recovery_entry.dart';

/// Domain boundary for the repertoire catalog. No filesystem or widget types.
abstract interface class RepertoireCatalogRepository {
  bool get supportsRecovery;
  Future<List<RepertoireMetadata>> listRepertoires();
  Future<List<RepertoireMetadata>> listChapters(String folderPath);
  Future<List<RepertoireMetadata>> listStudies();
  Future<List<RepertoireRecoveryEntry>> listRecovery();
  Future<void> restore(String id, {String? name});
  Future<RepertoireCreationResult> create(CreateRepertoire request);
  Future<void> rename(RepertoireMetadata repertoire, String name);

  /// Retains the repertoire's files in recovery storage.
  Future<void> moveToRecovery(RepertoireMetadata repertoire);
}
