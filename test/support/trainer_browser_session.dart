import 'package:chess_auto_prep/app/training_dependencies.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_board_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/training/controllers/training_session_controller.dart';
import 'package:chess_auto_prep/features/training/controllers/training_settings_controller.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../services/training/training_fakes.dart';
import 'generation_artifacts_fixture.dart';
import 'training_settings.dart';

Future<TrainingSessionController> trainerBrowserSession({
  required List<RepertoireLine> lines,
  String name = 'Colle',
  String? activeChapter,
  Map<String, RepertoireReviewEntry> reviewMap = const {},
  TrainingSettings? settings,
  FakeReviewService? reviews,
}) async {
  final configuration = TrainingSettingsController(
    MemoryTrainingSettings(
      settings ?? TrainingSettings(learnRequiresClick: true),
    ),
  );
  final session = createTrainingSession(
    artifacts: generationArtifactsFixture().repository,
    configuration: configuration,
    session: RepertoireBoardController(),
    repertoireService: FakeRepertoireService(),
    reviewService: reviews ?? FakeReviewService(),
  );
  addTearDown(configuration.dispose);
  addTearDown(session.dispose);
  session.setRepertoire(
    RepertoireMetadata(
      filePath: 'rep.pgn',
      name: name,
      lastModified: DateTime(2026),
    ),
  );
  session.isLoading = false;
  session.lines = lines;
  session.reviewMap.addAll(reviewMap);
  await session.loadSettings();
  session.setActiveChapter(activeChapter);
  return session;
}
