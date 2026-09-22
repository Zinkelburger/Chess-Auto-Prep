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
/// Mutable editing value; persistence belongs to TrainingSettingsController.
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
  TrainingSettings snapshot() => TrainingSettings(
    correctStreakThreshold: correctStreakThreshold,
    trainingDepth: trainingDepth,
    autoNext: autoNext,
    wrongMoveReplay: wrongMoveReplay,
    learnRequiresClick: learnRequiresClick,
    learnDelaySec: learnDelaySec,
    showRatingButtons: showRatingButtons,
    reviewOrder: reviewOrder,
    moveSpeedMs: moveSpeedMs,
    skipToFirstComment: skipToFirstComment,
    introSpeedMs: introSpeedMs,
    chapterGrouping: chapterGrouping,
    chapterDelimiter: chapterDelimiter,
    newLinesPerSession: newLinesPerSession,
    reviewsPerSession: reviewsPerSession,
  );
}
