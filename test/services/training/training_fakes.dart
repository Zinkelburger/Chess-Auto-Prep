/// In-memory stand-ins for the services a training session talks to, shared
/// by the trainer's unit tests.
library;

import 'package:chess_auto_prep/features/training/models/training_history_operation.dart';

import 'package:chess_auto_prep/features/training/models/training_source_context.dart';
import 'package:chess_auto_prep/models/completed_move.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/repertoire_move_progress.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/models/repertoire_review_history_entry.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/repertoire_file_editor.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Routes path_provider's documents directory to a per-test temp dir so any
/// storage fallback (e.g. the tree.json playability probe) touches real files
/// in an isolated location instead of the user's data.
class FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// In-memory [RepertoireService]: parse returns canned lines, header writes
/// are recorded instead of touching disk.
class FakeRepertoireService extends RepertoireService {
  List<RepertoireLine> lines = [];
  Object? parseError;
  final headerUpdates = <String>[];

  /// Every `(filePath, trainingColor)` parse call, in order.
  final parseCalls = <({String filePath, String? trainingColor})>[];

  @override
  Future<List<RepertoireLine>> parseRepertoireFile(
    String filePath, {
    String? trainingColor,
    bool colorFromStartingSide = false,
    bool inferColorWhenUnknown = false,
  }) async {
    parseCalls.add((filePath: filePath, trainingColor: trainingColor));
    if (parseError != null) throw parseError!;
    return List.of(lines);
  }

  @override
  Future<List<RepertoireLine>> parseTrainingSnapshot(
    String filePath,
    String content, {
    String? trainingColor,
    bool colorFromStartingSide = false,
    bool inferColorWhenUnknown = false,
  }) => parseRepertoireFile(
    filePath,
    trainingColor: trainingColor,
    colorFromStartingSide: colorFromStartingSide,
    inferColorWhenUnknown: inferColorWhenUnknown,
  );

  @override
  RepertoireFileEditor get files => RecordingFileEditor(headerUpdates);
}

/// [RepertoireFileEditor] whose review-header writes are recorded instead
/// of touching disk: the ids written, in order, and the file each batch was
/// aimed at.
class RecordingFileEditor extends RepertoireFileEditor {
  const RecordingFileEditor(this.headerUpdates, {this.headerPaths});

  final List<String> headerUpdates;
  final List<String>? headerPaths;

  @override
  Future<bool> updateLineReviewHeaders(
    String filePath,
    String lineId, {
    required DateTime? lastReview,
    required double difficulty,
    required double intervalDays,
    required DateTime? dueDate,
    required int passCount,
    required int failCount,
  }) async {
    headerUpdates.add(lineId);
    return true;
  }

  @override
  Future<bool> updateManyLineReviewHeaders(
    String filePath,
    Map<String, RepertoireReviewEntry> entriesByLineId, {
    required TrainingSourceContext source,
  }) async {
    headerUpdates.addAll(entriesByLineId.keys);
    headerPaths?.add(filePath);
    return true;
  }
}

/// In-memory [RepertoireReviewService]: the pure scheduling logic
/// (syncEntries, orderLinesForReview, applyRating) stays real; only the CSV
/// persistence is replaced.
class FakeReviewService extends RepertoireReviewService {
  List<RepertoireReviewEntry> entries = [];
  List<RepertoireMoveProgress> progress = [];
  final history = <RepertoireReviewHistoryEntry>[];
  int saveAllCalls = 0;
  final attemptedSources = <TrainingSourceContext>[];

  @override
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
  }) async {
    expect(source.path, repertoireId);
    attemptedSources.add(source);
  }

  Duration loadDelay = Duration.zero;

  @override
  Future<List<RepertoireReviewEntry>> loadAll() async {
    if (loadDelay > Duration.zero) await Future<void>.delayed(loadDelay);
    return List.of(entries);
  }

  @override
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    required TrainingSourceContext source,
    String? repertoireId,
  }) async {
    saveAllCalls++;
    this.entries = [
      if (repertoireId != null)
        for (final e in this.entries)
          if (e.repertoireId != repertoireId) e,
      ...entries,
    ];
  }

  @override
  Future<List<RepertoireMoveProgress>> loadMoveProgress() async =>
      List.of(progress);

  @override
  Future<void> saveMoveProgress(
    List<RepertoireMoveProgress> entries, {
    required TrainingSourceContext source,
    String? repertoireId,
  }) async {
    progress = List.of(entries);
  }

  @override
  Future<void> appendHistory(
    List<RepertoireReviewHistoryEntry> entries, {
    required TrainingSourceContext source,
    required TrainingHistoryOperation operation,
  }) async {
    history.addAll(entries);
  }
}

RepertoireLine fakeLine(
  String id,
  List<String> moves, {
  double? importance,
  Map<String, String> comments = const {},
  String? chapter,
}) {
  return RepertoireLine(
    id: id,
    name: 'Line $id',
    moves: moves,
    color: 'white',
    startPosition: Chess.initial,
    fullPgn: '',
    comments: comments,
    importance: importance,
    chapter: chapter,
  );
}

RepertoireReviewEntry fakeEntry(
  String repertoireId,
  String lineId, {
  String lastRating = 'good',
  DateTime? due,
  String lineName = '',
}) {
  return RepertoireReviewEntry(
    repertoireId: repertoireId,
    lineId: lineId,
    lineName: lineName.isEmpty ? lineId : lineName,
    lastRating: lastRating,
    dueDateUtc: due,
  );
}

CompletedMove fakeMove({String uci = '', String san = ''}) => CompletedMove(
  from: '',
  to: '',
  san: san,
  fenBefore: '',
  fenAfter: '',
  uci: uci,
);

/// 1 ms pacing everywhere so drill chains settle fast; learn stops at the
/// acknowledge gate instead of running timers.
TrainingSettings fastSettings({
  bool wrongMoveReplay = true,
  bool autoNext = false,
  ReviewOrder reviewOrder = ReviewOrder.sequential,
  int correctStreakThreshold = 3,
}) {
  return TrainingSettings(
    moveSpeedMs: 1,
    introSpeedMs: 1,
    skipToFirstComment: false,
    learnRequiresClick: true,
    wrongMoveReplay: wrongMoveReplay,
    autoNext: autoNext,
    reviewOrder: reviewOrder,
    correctStreakThreshold: correctStreakThreshold,
  );
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
