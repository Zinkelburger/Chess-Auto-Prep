import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// What kind of content the trainer drills.
///
/// Repertoire mode walks new lines through the learn phase before quizzing;
/// tactics mode always quizzes cold (showing a puzzle's solution first would
/// spoil it).
enum TrainingMode {
  repertoire('Repertoire'),
  tactics('Tactics');

  const TrainingMode(this.label);

  final String label;
}

/// How completed lines are scheduled.
///
/// Spaced repetition builds a due-queue with Again/Hard/Good/Easy ratings;
/// linear runs through every line once, in order, with no scheduling.
enum RepetitionMode {
  spaced('Spaced repetition'),
  linear('Linear');

  const RepetitionMode(this.label);

  final String label;
}

/// What a training run is working through.
///
/// Chessable keeps "learn new material" and "review what's due" as separate
/// sessions; auto-next stays inside the intent instead of hopping between
/// untrained and due lines mid-run.
enum TrainingIntent {
  learn('Learn'),
  review('Review');

  const TrainingIntent(this.label);

  final String label;
}

/// How the repertoire trainer orders lines for review.
enum ReviewOrder {
  byImportance('By cumulative probability (most likely first)'),
  random('Random'),
  weakestFirst('Weakest first'),
  hardestFirst('Hardest to play first'),
  sequential('Sequential');

  const ReviewOrder(this.label);

  final String label;

  /// The order persisted as [storageValue], or [byImportance] when unset
  /// or unknown.
  static ReviewOrder fromStorage(String? value) =>
      values.asNameMap()[value] ?? ReviewOrder.byImportance;

  /// Key written to SharedPreferences: the enum name.
  String get storageValue => name;
}

/// Where the trainer reads chapter names from when grouping lines.
enum ChapterGroupingMode {
  auto(
    'Automatic (course headers)',
    "Chapters from the file's own metadata (Chessable exports name the "
        "chapter in every game's White header).",
  ),
  namePrefix(
    'Line-name prefix',
    'Everything in the line name before the delimiter is the chapter.',
  ),
  off('Off', 'No chapter grouping.');

  const ChapterGroupingMode(this.label, this.description);

  final String label;
  final String description;

  /// The mode persisted as [storageValue], or [auto] when unset or unknown.
  static ChapterGroupingMode fromStorage(String? value) =>
      values.asNameMap()[value] ?? ChapterGroupingMode.auto;

  /// Key written to SharedPreferences: the enum name.
  String get storageValue => name;
}

/// The trainer's user preferences, persisted in SharedPreferences.
///
/// Mutable on purpose: the settings sheet edits fields in place and calls
/// [save] (or [saveSoon]) when it closes.
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

  /// If true, moves before the first commented move are auto-played on the
  /// board (at intro speed) instead of being quizzed; training starts at the
  /// first move that has a comment.
  bool skipToFirstComment;

  /// Delay in milliseconds between auto-played intro moves.
  int introSpeedMs;

  /// Where chapter names come from when grouping the line list.
  ChapterGroupingMode chapterGrouping;

  /// Delimiter for [ChapterGroupingMode.namePrefix]: the chapter is
  /// everything in the line name before its first occurrence.
  String chapterDelimiter;

  /// How many untrained lines one "Learn" run works through before it calls
  /// the sitting done. 0 = no limit.
  ///
  /// A bought course is hundreds of lines; without a cap the trainer opened
  /// with "930 left in this run", which is not a session, it is a wall. Anki
  /// caps new cards per day for the same reason — the limit is what makes the
  /// backlog finishable.
  int newLinesPerSession;

  /// How many due lines one "Review" run works through. 0 = no limit.
  int reviewsPerSession;

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
    this.skipToFirstComment = true,
    this.introSpeedMs = 600,
    this.chapterGrouping = ChapterGroupingMode.auto,
    this.chapterDelimiter = '#',
    this.newLinesPerSession = 0,
    this.reviewsPerSession = 0,
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
  static const _keySkipToFirstComment = 'trainer_skip_to_first_comment';
  static const _keyIntroSpeedMs = 'trainer_intro_speed_ms';
  static const _keyChapterGrouping = 'trainer_chapter_grouping';
  static const _keyChapterDelimiter = 'trainer_chapter_delimiter';
  static const _keyNewPerSession = 'trainer_new_lines_per_session';
  static const _keyReviewsPerSession = 'trainer_reviews_per_session';

  static Future<TrainingSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    // Old versions silently imposed these caps. Migrate those defaults once;
    // explicit sizes chosen after this migration remain user preferences.
    if (!(prefs.getBool('trainer_uncapped_default_v1') ?? false)) {
      if (prefs.getInt(_keyNewPerSession) == 10) {
        await prefs.setInt(_keyNewPerSession, 0);
      }
      if (prefs.getInt(_keyReviewsPerSession) == 40) {
        await prefs.setInt(_keyReviewsPerSession, 0);
      }
      await prefs.setBool('trainer_uncapped_default_v1', true);
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

  void saveSoon() => unawaited(save());

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyStreakThreshold, correctStreakThreshold);
    if (trainingDepth case final depth?) {
      await prefs.setInt(_keyTrainingDepth, depth);
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
    await prefs.setBool(_keySkipToFirstComment, skipToFirstComment);
    await prefs.setInt(_keyIntroSpeedMs, introSpeedMs);
    await prefs.setString(_keyChapterGrouping, chapterGrouping.storageValue);
    await prefs.setString(_keyChapterDelimiter, chapterDelimiter);
    await prefs.setInt(_keyNewPerSession, newLinesPerSession);
    await prefs.setInt(_keyReviewsPerSession, reviewsPerSession);
  }
}
