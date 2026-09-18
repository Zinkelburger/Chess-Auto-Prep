import '../../documents/models/pgn_document.dart';
import '../../training/models/chapter_layout.dart' show ChapterSummary;
import '../models/repertoire_creation.dart';
import '../models/repertoire_metadata.dart';
import '../models/repertoire_recovery_entry.dart';

/// Domain boundary for the repertoire catalog. No filesystem or widget types.
abstract interface class RepertoireCatalogRepository {
  bool get supportsRecovery;
  Future<List<RepertoireMetadata>> listRepertoires();
  Future<List<RepertoireMetadata>> listChapters(String folderPath);
  Future<List<ChapterSummary>> chapterSections(String path);

  /// Capture only a verified, managed chapter before asking for deletion.
  Future<PgnOpenResult> prepareChapterDeletion(String path);

  /// Remove only the captured native object; uncertainty is not acknowledgement.
  Future<PgnQuarantineResult> deleteChapter(PgnSnapshot baseline);

  /// Exclusively creates an empty chapter. Null color inherits the first
  /// available color header in this folder, or White when none exists.
  /// Read failures are failures, never permission to guess the color.
  Future<PgnWriteResult> createChapter({
    required String folderPath,
    required String name,
    bool? isWhite,
  });
  Future<List<RepertoireMetadata>> listStudies();
  Future<List<RepertoireRecoveryEntry>> listRecovery();
  Future<void> restore(String id, {String? name});
  Future<RepertoireCreationResult> create(CreateRepertoire request);
  Future<void> rename(RepertoireMetadata repertoire, String name);

  /// Retains the repertoire's files in recovery storage.
  Future<void> moveToRecovery(RepertoireMetadata repertoire);
}
