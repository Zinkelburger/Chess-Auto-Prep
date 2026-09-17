import '../features/repertoires/controllers/repertoire_controller.dart';
import '../features/training/controllers/training_session_controller.dart';
import '../infrastructure/training/preferences_training_settings.dart';
import '../infrastructure/training/training_source_loader.dart';
import '../services/asked_questions_store.dart';
import '../services/repertoire_review_service.dart';
import '../services/repertoire_service.dart';

/// Production bridges are constructed once per training owner.
TrainingSessionController createTrainingSession({
  required RepertoireController session,
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
      repertoireService: repertoire,
      reviewService: reviews,
      askedQuestions: answers,
    ),
    configuration: PreferencesTrainingSettings(),
    reviewService: reviews,
    askedQuestions: answers,
  );
}
