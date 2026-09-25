import '../models/training_history_operation.dart';
import '../models/training_source_context.dart';
import '../../../models/repertoire_line.dart';
import '../../../models/repertoire_move_progress.dart';
import '../../../models/repertoire_review_entry.dart';
import '../../../models/repertoire_review_history_entry.dart';
import '../models/training_settings.dart';

/// Existing review formats and optimistic conflict rules remain owned by the adapter.
abstract interface class TrainingReviewRepository {
  Future<List<RepertoireReviewEntry>> loadAll();
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    String? repertoireId,
    required TrainingSourceContext source,
  });
  Future<List<RepertoireMoveProgress>> loadMoveProgress();
  Future<void> saveMoveProgress(
    List<RepertoireMoveProgress> entries, {
    String? repertoireId,
    required TrainingSourceContext source,
  });
  Future<List<RepertoireReviewHistoryEntry>> loadHistory();
  Future<void> appendHistory(
    List<RepertoireReviewHistoryEntry> entries, {
    required TrainingSourceContext source,
    required TrainingHistoryOperation operation,
  });
  Future<List<Map<String, dynamic>>> loadAttempts({String? repertoireId});
  Future<void> recordAttempt({
    required String repertoireId,
    required TrainingSourceContext source,
    required String lineId,
    required int moveIndex,
    required String fen,
    required String playedSan,
    required String expectedSan,
    required bool correct,
    required String phase,
  });
  RepertoireReviewEntry applyRating(
    RepertoireReviewEntry entry,
    ReviewRating rating,
  );
  double previewInterval(RepertoireReviewEntry entry, ReviewRating rating);
  List<RepertoireLine> orderLinesForReview(
    List<RepertoireLine> lines,
    Map<String, RepertoireReviewEntry> reviewMap,
    ReviewOrder order, {
    Map<String, double>? playabilityMap,
    bool dueOnly = true,
  });
}

abstract interface class TrainingHeaderRepository {
  Future<bool> updateManyLineReviewHeaders(
    String sourcePath,
    Map<String, RepertoireReviewEntry> entries, {
    required TrainingSourceContext source,
  });
}
