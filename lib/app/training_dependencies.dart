import '../features/generation/repositories/generation_artifact_repository.dart';
import '../features/repertoires/controllers/repertoire_board_controller.dart';
import '../features/training/controllers/training_session_controller.dart';
import '../features/training/controllers/training_settings_controller.dart';
import '../infrastructure/training/preferences_training_settings.dart';
import '../infrastructure/training/training_source_loader.dart';
import '../services/asked_questions_store.dart';
import '../services/repertoire_review_service.dart';
import '../services/repertoire_service.dart';

TrainingSettingsController createTrainingSettings() =>
    TrainingSettingsController(PreferencesTrainingSettings());

/// Session bridges share the injected application configuration owner.
TrainingSessionController createTrainingSession({
  required RepertoireBoardController session,
  required GenerationArtifactRepository artifacts,
  required TrainingSettingsController configuration,
  RepertoireService? repertoireService,
  RepertoireReviewService? reviewService,
  AskedQuestionsStore? askedQuestions,
}) {
  final repertoire = repertoireService ?? RepertoireService();
  final reviews = reviewService ?? RepertoireReviewService();
  final answers = askedQuestions ?? AskedQuestionsStore();
  return TrainingSessionController(
    session: session,
    headers: repertoire.files,
    source: TrainingSourceLoader(
      artifacts: artifacts,
      repertoireService: repertoire,
      reviewService: reviews,
      askedQuestions: answers,
    ),
    configuration: configuration,
    reviewService: reviews,
    askedQuestions: answers,
  );
}
