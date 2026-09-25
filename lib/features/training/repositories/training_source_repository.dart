import '../models/training_source_context.dart';
import '../../../models/repertoire_line.dart';
import '../../../models/repertoire_move_progress.dart';
import '../../../models/repertoire_review_entry.dart';
import '../../repertoires/models/repertoire_metadata.dart';

/// Everything a training session needs from a freshly loaded source.
class LoadedTrainingSource {
  const LoadedTrainingSource({
    required this.lines,
    required this.sources,
    required this.reviewByLine,
    required this.moveProgress,
    required this.otherRepertoires,
    required this.isFolder,
  });

  final Map<String, TrainingSourceContext> sources;

  /// Parsed lines in file order. Empty when the source holds nothing to train.
  final List<RepertoireLine> lines;

  /// Review entries keyed by [RepertoireLine.id], synced and already saved.
  final Map<String, RepertoireReviewEntry> reviewByLine;

  /// Per-move streaks keyed `"<lineId>:<moveIndex>"`.
  final Map<String, RepertoireMoveProgress> moveProgress;

  /// Stored entries belonging to sources other than this one.
  final List<RepertoireReviewEntry> otherRepertoires;

  /// True when the source was a folder of chapter files. Folders and studies
  /// have no generated tree, so [TrainingSourceRepository.playabilityFromTree]
  /// only applies to a single repertoire file.
  final bool isFolder;
}

abstract interface class TrainingSourceRepository {
  Future<LoadedTrainingSource?> load(
    RepertoireMetadata source, {
    required bool isStudy,
    required bool? colorOverrideIsWhite,
    required bool Function() isStale,
    void Function(String status)? onStatus,
  });
  Future<Map<String, double>> playabilityFromTree(
    String filePath,
    List<RepertoireLine> lines, {
    required bool Function() isStale,
  });
}
