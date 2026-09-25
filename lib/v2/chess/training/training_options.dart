/// Preferences captured when a sitting starts; zero means no line limit.
final class TrainingOptions {
  const TrainingOptions({
    this.learnLimit = 10,
    this.reviewLimit = 0,
    this.replyMillis = 700,
    this.replayMistakes = true,
    this.rateReviews = false,
  });

  final int learnLimit;
  final int reviewLimit;
  final int replyMillis;
  final bool replayMistakes;

  /// Whether a reviewed line waits for the user's Again/Hard/Good/Easy,
  /// Anki's way, rather than being graded from its mistakes as Chessable
  /// grades it; the grade the mistakes earned is then the one Space takes.
  /// A line new to the sitting is always graded.
  final bool rateReviews;

  static const defaults = TrainingOptions();

  TrainingOptions copyWith({
    int? learnLimit,
    int? reviewLimit,
    int? replyMillis,
    bool? replayMistakes,
    bool? rateReviews,
  }) => TrainingOptions(
    learnLimit: learnLimit ?? this.learnLimit,
    reviewLimit: reviewLimit ?? this.reviewLimit,
    replyMillis: replyMillis ?? this.replyMillis,
    replayMistakes: replayMistakes ?? this.replayMistakes,
    rateReviews: rateReviews ?? this.rateReviews,
  );

  Map<String, Object> toJson() => {
    'learnLimit': learnLimit,
    'reviewLimit': reviewLimit,
    'replyMillis': replyMillis,
    'replayMistakes': replayMistakes,
    'rateReviews': rateReviews,
  };

  factory TrainingOptions.fromJson(Object? value) {
    if (value is! Map<String, Object?>) return defaults;
    int number(String key, int fallback, int min, int max) {
      final n = value[key];
      return n is int ? n.clamp(min, max) : fallback;
    }

    return TrainingOptions(
      learnLimit: number('learnLimit', 10, 0, 1000),
      reviewLimit: number('reviewLimit', 0, 0, 1000),
      replyMillis: number('replyMillis', 700, 200, 2000),
      replayMistakes: value['replayMistakes'] is bool
          ? value['replayMistakes'] as bool
          : true,
      rateReviews: value['rateReviews'] is bool
          ? value['rateReviews'] as bool
          : false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrainingOptions &&
      learnLimit == other.learnLimit &&
      reviewLimit == other.reviewLimit &&
      replyMillis == other.replyMillis &&
      replayMistakes == other.replayMistakes &&
      rateReviews == other.rateReviews;

  @override
  int get hashCode => Object.hash(
    learnLimit,
    reviewLimit,
    replyMillis,
    replayMistakes,
    rateReviews,
  );
}
