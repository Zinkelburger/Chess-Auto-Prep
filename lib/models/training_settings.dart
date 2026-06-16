import 'package:shared_preferences/shared_preferences.dart';

/// How the repertoire trainer orders lines for review.
enum ReviewOrder {
  byImportance,
  random,
  weakestFirst,
  sequential,
}

extension ReviewOrderLabel on ReviewOrder {
  String get label => switch (this) {
        ReviewOrder.byImportance =>
          'By cumulative probability (most likely first)',
        ReviewOrder.random => 'Random',
        ReviewOrder.weakestFirst => 'Weakest first',
        ReviewOrder.sequential => 'Sequential',
      };

  static ReviewOrder fromStorage(String? value) {
    switch (value) {
      case 'random':
        return ReviewOrder.random;
      case 'weakestFirst':
        return ReviewOrder.weakestFirst;
      case 'sequential':
        return ReviewOrder.sequential;
      default:
        return ReviewOrder.byImportance;
    }
  }

  String get storageValue => switch (this) {
        ReviewOrder.byImportance => 'byImportance',
        ReviewOrder.random => 'random',
        ReviewOrder.weakestFirst => 'weakestFirst',
        ReviewOrder.sequential => 'sequential',
      };
}

class TrainingSettings {
  int correctStreakThreshold;
  int? trainingDepth; // null = full line
  bool autoNext;
  bool wrongMoveReplay;

  /// When learning new moves: require user to press spacebar/button
  /// before being quizzed, or auto-advance after a delay.
  bool learnRequiresClick;

  /// If learnRequiresClick is false, how many seconds to show the
  /// move + annotation before auto-quizzing. (1–15)
  int learnDelaySec;

  /// If true, show Again/Hard/Good/Easy buttons (with 1-4 shortcuts).
  /// If false, auto-rate based on whether user made mistakes.
  bool showRatingButtons;

  /// Order in which due lines are presented for review.
  ReviewOrder reviewOrder;

  /// Base delay in milliseconds for opponent/auto moves (200–2000).
  int moveSpeedMs;

  TrainingSettings({
    this.correctStreakThreshold = 3,
    this.trainingDepth,
    this.autoNext = true,
    this.wrongMoveReplay = true,
    this.learnRequiresClick = true,
    this.learnDelaySec = 3,
    this.showRatingButtons = true,
    this.reviewOrder = ReviewOrder.byImportance,
    this.moveSpeedMs = 700,
  });

  static const _keyStreakThreshold = 'trainer_streak_threshold';
  static const _keyTrainingDepth = 'trainer_training_depth';
  static const _keyAutoNext = 'trainer_auto_next';
  static const _keyWrongMoveReplay = 'trainer_wrong_move_replay';
  static const _keyLearnRequiresClick = 'trainer_learn_requires_click';
  static const _keyLearnDelaySec = 'trainer_learn_delay_sec';
  static const _keyShowRatingButtons = 'trainer_show_rating_buttons';
  static const _keyReviewOrder = 'trainer_review_order';
  static const _keyMoveSpeedMs = 'trainer_move_speed_ms';

  static Future<TrainingSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return TrainingSettings(
      correctStreakThreshold: prefs.getInt(_keyStreakThreshold) ?? 3,
      trainingDepth: prefs.getInt(_keyTrainingDepth),
      autoNext: prefs.getBool(_keyAutoNext) ?? true,
      wrongMoveReplay: prefs.getBool(_keyWrongMoveReplay) ?? true,
      learnRequiresClick: prefs.getBool(_keyLearnRequiresClick) ?? true,
      learnDelaySec: prefs.getInt(_keyLearnDelaySec) ?? 3,
      showRatingButtons: prefs.getBool(_keyShowRatingButtons) ?? true,
      reviewOrder:
          ReviewOrderLabel.fromStorage(prefs.getString(_keyReviewOrder)),
      moveSpeedMs: prefs.getInt(_keyMoveSpeedMs) ?? 700,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyStreakThreshold, correctStreakThreshold);
    if (trainingDepth != null) {
      await prefs.setInt(_keyTrainingDepth, trainingDepth!);
    } else {
      await prefs.remove(_keyTrainingDepth);
    }
    await prefs.setBool(_keyAutoNext, autoNext);
    await prefs.setBool(_keyWrongMoveReplay, wrongMoveReplay);
    await prefs.setBool(_keyLearnRequiresClick, learnRequiresClick);
    await prefs.setInt(_keyLearnDelaySec, learnDelaySec);
    await prefs.setBool(_keyShowRatingButtons, showRatingButtons);
    await prefs.setString(_keyReviewOrder, reviewOrder.storageValue);
    await prefs.setInt(_keyMoveSpeedMs, moveSpeedMs);
  }
}
