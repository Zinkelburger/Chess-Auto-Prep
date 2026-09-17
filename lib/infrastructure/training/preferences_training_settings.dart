import 'package:shared_preferences/shared_preferences.dart';
import '../../features/training/models/training_settings.dart';
import '../../features/training/models/training_configuration.dart';
import '../../features/training/repositories/training_settings_repository.dart';

class PreferencesTrainingSettings implements TrainingSettingsStorage {
  static const _keyStreakThreshold = 'trainer_streak_threshold';
  static const _keyTrainingDepth = 'trainer_training_depth';
  static const _keyAutoNext = 'trainer_auto_next';
  static const _keyWrongMoveReplay = 'trainer_wrong_move_replay';
  static const _keyLearnRequiresClick = 'trainer_learn_requires_click';
  static const _keyLearnDelaySec = 'trainer_learn_delay_sec';
  static const _keyShowRatingButtons = 'trainer_show_rating_buttons';
  static const _keyReviewOrder = 'trainer_review_order';
  static const _keyMoveSpeedMs = 'trainer_move_speed_ms';
  static const _keySkipToFirstComment = 'trainer_skip_to_first_comment';
  static const _keyIntroSpeedMs = 'trainer_intro_speed_ms';
  static const _keyChapterGrouping = 'trainer_chapter_grouping';
  static const _keyChapterDelimiter = 'trainer_chapter_delimiter';
  static const _keyNewPerSession = 'trainer_new_lines_per_session';
  static const _keyReviewsPerSession = 'trainer_reviews_per_session';

  @override
  Future<TrainingConfiguration> read() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    // Old versions silently imposed these caps. Migrate those defaults once;
    // explicit sizes chosen after this migration remain user preferences.
    if (!(prefs.getBool('trainer_uncapped_default_v1') ?? false)) {
      if (prefs.getInt(_keyNewPerSession) == 10) {
        await _write(prefs.setInt(_keyNewPerSession, 0));
      }
      if (prefs.getInt(_keyReviewsPerSession) == 40) {
        await _write(prefs.setInt(_keyReviewsPerSession, 0));
      }
      await _write(prefs.setBool('trainer_uncapped_default_v1', true));
    }
    return TrainingConfiguration(
      TrainingSettings(
        correctStreakThreshold: prefs.getInt(_keyStreakThreshold) ?? 3,
        trainingDepth: prefs.getInt(_keyTrainingDepth),
        autoNext: prefs.getBool(_keyAutoNext) ?? true,
        wrongMoveReplay: prefs.getBool(_keyWrongMoveReplay) ?? true,
        learnRequiresClick: prefs.getBool(_keyLearnRequiresClick) ?? true,
        learnDelaySec: prefs.getInt(_keyLearnDelaySec) ?? 3,
        showRatingButtons: prefs.getBool(_keyShowRatingButtons) ?? true,
        reviewOrder: ReviewOrder.fromStorage(prefs.getString(_keyReviewOrder)),
        moveSpeedMs: prefs.getInt(_keyMoveSpeedMs) ?? 700,
        skipToFirstComment: prefs.getBool(_keySkipToFirstComment) ?? true,
        introSpeedMs: prefs.getInt(_keyIntroSpeedMs) ?? 600,
        chapterGrouping: ChapterGroupingMode.fromStorage(
          prefs.getString(_keyChapterGrouping),
        ),
        chapterDelimiter: prefs.getString(_keyChapterDelimiter) ?? '#',
        newLinesPerSession: prefs.getInt(_keyNewPerSession) ?? 0,
        reviewsPerSession: prefs.getInt(_keyReviewsPerSession) ?? 0,
      ),
    );
  }

  Future<void> _write(Future<bool> result) async {
    if (!await result) throw StateError('Training preferences were not saved.');
  }

  @override
  Future<void> write(TrainingSettingsPatch edit) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in edit.changes.entries) {
      final value = entry.value;
      switch (entry.key) {
        case TrainingSetting.correctStreakThreshold:
          await _write(prefs.setInt(_keyStreakThreshold, value as int));
        case TrainingSetting.trainingDepth:
          await _write(
            value == null
                ? prefs.remove(_keyTrainingDepth)
                : prefs.setInt(_keyTrainingDepth, value as int),
          );
        case TrainingSetting.autoNext:
          await _write(prefs.setBool(_keyAutoNext, value as bool));
        case TrainingSetting.wrongMoveReplay:
          await _write(prefs.setBool(_keyWrongMoveReplay, value as bool));
        case TrainingSetting.learnRequiresClick:
          await _write(prefs.setBool(_keyLearnRequiresClick, value as bool));
        case TrainingSetting.learnDelaySec:
          await _write(prefs.setInt(_keyLearnDelaySec, value as int));
        case TrainingSetting.showRatingButtons:
          await _write(prefs.setBool(_keyShowRatingButtons, value as bool));
        case TrainingSetting.reviewOrder:
          await _write(
            prefs.setString(
              _keyReviewOrder,
              (value as ReviewOrder).storageValue,
            ),
          );
        case TrainingSetting.moveSpeedMs:
          await _write(prefs.setInt(_keyMoveSpeedMs, value as int));
        case TrainingSetting.skipToFirstComment:
          await _write(prefs.setBool(_keySkipToFirstComment, value as bool));
        case TrainingSetting.introSpeedMs:
          await _write(prefs.setInt(_keyIntroSpeedMs, value as int));
        case TrainingSetting.chapterGrouping:
          await _write(
            prefs.setString(
              _keyChapterGrouping,
              (value as ChapterGroupingMode).storageValue,
            ),
          );
        case TrainingSetting.chapterDelimiter:
          await _write(prefs.setString(_keyChapterDelimiter, value as String));
        case TrainingSetting.newLinesPerSession:
          await _write(prefs.setInt(_keyNewPerSession, value as int));
        case TrainingSetting.reviewsPerSession:
          await _write(prefs.setInt(_keyReviewsPerSession, value as int));
      }
    }
  }
}
