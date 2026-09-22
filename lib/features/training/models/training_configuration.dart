import '../../settings/models/section_configuration.dart';
import 'training_settings.dart';

/// Immutable committed/draft preferences; each sitting receives an editing copy.
class TrainingConfiguration extends ImmutableSection<TrainingConfiguration> {
  TrainingConfiguration(TrainingSettings settings)
    : super({
        'trainer_streak_threshold': settings.correctStreakThreshold,
        'trainer_training_depth': settings.trainingDepth,
        'trainer_auto_next': settings.autoNext,
        'trainer_wrong_move_replay': settings.wrongMoveReplay,
        'trainer_learn_requires_click': settings.learnRequiresClick,
        'trainer_learn_delay_sec': settings.learnDelaySec,
        'trainer_show_rating_buttons': settings.showRatingButtons,
        'trainer_review_order': settings.reviewOrder.storageValue,
        'trainer_move_speed_ms': settings.moveSpeedMs,
        'trainer_skip_to_first_comment': settings.skipToFirstComment,
        'trainer_intro_speed_ms': settings.introSpeedMs,
        'trainer_chapter_grouping': settings.chapterGrouping.storageValue,
        'trainer_chapter_delimiter': settings.chapterDelimiter,
        'trainer_new_lines_per_session': settings.newLinesPerSession,
        'trainer_reviews_per_session': settings.reviewsPerSession,
      });
  TrainingConfiguration._(super.values);

  factory TrainingConfiguration.fromValues(Map<String, Object?> input) {
    final defaults = TrainingConfiguration(TrainingSettings());
    final decoded = TrainingConfiguration._({
      for (final entry in defaults.values.entries)
        entry.key: input[entry.key] ?? entry.value,
    });
    return TrainingConfiguration(decoded.toSettings());
  }

  @override
  TrainingConfiguration withValues(Map<String, Object?> values) =>
      TrainingConfiguration.fromValues(values);

  /// Captures only changed fields, including explicit null for full-line depth.
  Map<String, Object?> changesFrom(TrainingConfiguration before) =>
      Map.unmodifiable({
        for (final entry in values.entries)
          if (before.values[entry.key] != entry.value) entry.key: entry.value,
      });

  TrainingSettings toSettings() => TrainingSettings(
    correctStreakThreshold: values['trainer_streak_threshold'] as int,
    trainingDepth: values['trainer_training_depth'] as int?,
    autoNext: values['trainer_auto_next'] as bool,
    wrongMoveReplay: values['trainer_wrong_move_replay'] as bool,
    learnRequiresClick: values['trainer_learn_requires_click'] as bool,
    learnDelaySec: values['trainer_learn_delay_sec'] as int,
    showRatingButtons: values['trainer_show_rating_buttons'] as bool,
    reviewOrder: ReviewOrder.fromStorage(
      values['trainer_review_order'] as String?,
    ),
    moveSpeedMs: values['trainer_move_speed_ms'] as int,
    skipToFirstComment: values['trainer_skip_to_first_comment'] as bool,
    introSpeedMs: values['trainer_intro_speed_ms'] as int,
    chapterGrouping: ChapterGroupingMode.fromStorage(
      values['trainer_chapter_grouping'] as String?,
    ),
    chapterDelimiter: values['trainer_chapter_delimiter'] as String,
    newLinesPerSession: values['trainer_new_lines_per_session'] as int,
    reviewsPerSession: values['trainer_reviews_per_session'] as int,
  );
}
