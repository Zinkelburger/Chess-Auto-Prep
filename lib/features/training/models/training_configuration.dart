import 'training_settings.dart';

/// Stable field identities permit independent panels to edit only what changed.
enum TrainingSetting {
  correctStreakThreshold,
  trainingDepth,
  autoNext,
  wrongMoveReplay,
  learnRequiresClick,
  learnDelaySec,
  showRatingButtons,
  reviewOrder,
  moveSpeedMs,
  skipToFirstComment,
  introSpeedMs,
  chapterGrouping,
  chapterDelimiter,
  newLinesPerSession,
  reviewsPerSession,
}

/// Immutable committed/draft projection. The mutable value is only an editing copy.
class TrainingConfiguration {
  TrainingConfiguration(TrainingSettings settings)
    : _values = Map.unmodifiable({
        TrainingSetting.correctStreakThreshold: settings.correctStreakThreshold,
        TrainingSetting.trainingDepth: settings.trainingDepth,
        TrainingSetting.autoNext: settings.autoNext,
        TrainingSetting.wrongMoveReplay: settings.wrongMoveReplay,
        TrainingSetting.learnRequiresClick: settings.learnRequiresClick,
        TrainingSetting.learnDelaySec: settings.learnDelaySec,
        TrainingSetting.showRatingButtons: settings.showRatingButtons,
        TrainingSetting.reviewOrder: settings.reviewOrder,
        TrainingSetting.moveSpeedMs: settings.moveSpeedMs,
        TrainingSetting.skipToFirstComment: settings.skipToFirstComment,
        TrainingSetting.introSpeedMs: settings.introSpeedMs,
        TrainingSetting.chapterGrouping: settings.chapterGrouping,
        TrainingSetting.chapterDelimiter: settings.chapterDelimiter,
        TrainingSetting.newLinesPerSession: settings.newLinesPerSession,
        TrainingSetting.reviewsPerSession: settings.reviewsPerSession,
      });
  TrainingConfiguration._(Map<TrainingSetting, Object?> values)
    : _values = Map.unmodifiable(values);
  final Map<TrainingSetting, Object?> _values;
  Object? value(TrainingSetting field) => _values[field];

  TrainingSettings toSettings() => TrainingSettings(
    correctStreakThreshold:
        _values[TrainingSetting.correctStreakThreshold] as int,
    trainingDepth: _values[TrainingSetting.trainingDepth] as int?,
    autoNext: _values[TrainingSetting.autoNext] as bool,
    wrongMoveReplay: _values[TrainingSetting.wrongMoveReplay] as bool,
    learnRequiresClick: _values[TrainingSetting.learnRequiresClick] as bool,
    learnDelaySec: _values[TrainingSetting.learnDelaySec] as int,
    showRatingButtons: _values[TrainingSetting.showRatingButtons] as bool,
    reviewOrder: _values[TrainingSetting.reviewOrder] as ReviewOrder,
    moveSpeedMs: _values[TrainingSetting.moveSpeedMs] as int,
    skipToFirstComment: _values[TrainingSetting.skipToFirstComment] as bool,
    introSpeedMs: _values[TrainingSetting.introSpeedMs] as int,
    chapterGrouping:
        _values[TrainingSetting.chapterGrouping] as ChapterGroupingMode,
    chapterDelimiter: _values[TrainingSetting.chapterDelimiter] as String,
    newLinesPerSession: _values[TrainingSetting.newLinesPerSession] as int,
    reviewsPerSession: _values[TrainingSetting.reviewsPerSession] as int,
  );

  @override
  bool operator ==(Object other) =>
      other is TrainingConfiguration &&
      TrainingSetting.values.every(
        (field) => other._values[field] == _values[field],
      );
  @override
  int get hashCode =>
      Object.hashAll(TrainingSetting.values.map((field) => _values[field]));
}

/// Captured field edits, never a replacement made from another panel's stale copy.
class TrainingSettingsPatch {
  TrainingSettingsPatch.between(
    TrainingConfiguration before,
    TrainingConfiguration after,
  ) : changes = Map.unmodifiable({
        for (final field in TrainingSetting.values)
          if (before.value(field) != after.value(field))
            field: after.value(field),
      });
  TrainingSettingsPatch._(Map<TrainingSetting, Object?> values)
    : changes = Map.unmodifiable(values);
  final Map<TrainingSetting, Object?> changes;
  TrainingSettingsPatch followedBy(TrainingSettingsPatch later) =>
      TrainingSettingsPatch._({...changes, ...later.changes});
  TrainingSettingsPatch without(Iterable<TrainingSetting> fields) =>
      TrainingSettingsPatch._({
        for (final entry in changes.entries)
          if (!fields.contains(entry.key)) entry.key: entry.value,
      });
  bool get isEmpty => changes.isEmpty;
  TrainingConfiguration apply(TrainingConfiguration current) =>
      TrainingConfiguration._({...current._values, ...changes});
}
