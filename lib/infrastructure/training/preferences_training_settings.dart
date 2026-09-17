import 'package:shared_preferences/shared_preferences.dart';
import '../../features/training/models/training_settings.dart';
import '../../features/training/repositories/training_settings_repository.dart';

class PreferencesTrainingSettings implements TrainingSettingsRepository {
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

  static Future<void> _tail = Future.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<TrainingSettings> load() => _serialize(_load);

  Future<TrainingSettings> _load() async {
    final prefs = await SharedPreferences.getInstance();
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
    return TrainingSettings(
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
    );
  }

  @override
  Future<void> save(TrainingSettings settings) {
    final snapshot = settings.snapshot();
    return _serialize(() => _save(snapshot));
  }

  Future<void> _write(Future<bool> result) async {
    if (!await result) throw StateError('Training preferences were not saved.');
  }

  Future<void> _save(TrainingSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await _write(
      prefs.setInt(_keyStreakThreshold, settings.correctStreakThreshold),
    );
    if (settings.trainingDepth case final depth?) {
      await _write(prefs.setInt(_keyTrainingDepth, depth));
    } else {
      await _write(prefs.remove(_keyTrainingDepth));
    }
    await _write(prefs.setBool(_keyAutoNext, settings.autoNext));
    await _write(prefs.setBool(_keyWrongMoveReplay, settings.wrongMoveReplay));
    await _write(
      prefs.setBool(_keyLearnRequiresClick, settings.learnRequiresClick),
    );
    await _write(prefs.setInt(_keyLearnDelaySec, settings.learnDelaySec));
    await _write(
      prefs.setBool(_keyShowRatingButtons, settings.showRatingButtons),
    );
    await _write(
      prefs.setString(_keyReviewOrder, settings.reviewOrder.storageValue),
    );
    await _write(prefs.setInt(_keyMoveSpeedMs, settings.moveSpeedMs));
    await _write(
      prefs.setBool(_keySkipToFirstComment, settings.skipToFirstComment),
    );
    await _write(prefs.setInt(_keyIntroSpeedMs, settings.introSpeedMs));
    await _write(
      prefs.setString(
        _keyChapterGrouping,
        settings.chapterGrouping.storageValue,
      ),
    );
    await _write(
      prefs.setString(_keyChapterDelimiter, settings.chapterDelimiter),
    );
    await _write(prefs.setInt(_keyNewPerSession, settings.newLinesPerSession));
    await _write(
      prefs.setInt(_keyReviewsPerSession, settings.reviewsPerSession),
    );
  }
}
