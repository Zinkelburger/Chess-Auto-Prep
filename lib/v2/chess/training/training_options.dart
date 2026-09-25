/// Preferences captured when a sitting starts; zero means no line limit.
final class TrainingOptions {
  const TrainingOptions({
    this.learnLimit = 10,
    this.reviewLimit = 0,
    this.drillLimit = 10,
    this.replyMillis = 700,
    this.replayMistakes = true,
    this.shuffleDrill = false,
  });

  final int learnLimit;
  final int reviewLimit;
  final int drillLimit;
  final int replyMillis;
  final bool replayMistakes;
  final bool shuffleDrill;

  static const defaults = TrainingOptions();

  TrainingOptions copyWith({
    int? learnLimit,
    int? reviewLimit,
    int? drillLimit,
    int? replyMillis,
    bool? replayMistakes,
    bool? shuffleDrill,
  }) => TrainingOptions(
    learnLimit: learnLimit ?? this.learnLimit,
    reviewLimit: reviewLimit ?? this.reviewLimit,
    drillLimit: drillLimit ?? this.drillLimit,
    replyMillis: replyMillis ?? this.replyMillis,
    replayMistakes: replayMistakes ?? this.replayMistakes,
    shuffleDrill: shuffleDrill ?? this.shuffleDrill,
  );

  Map<String, Object> toJson() => {
    'learnLimit': learnLimit,
    'reviewLimit': reviewLimit,
    'drillLimit': drillLimit,
    'replyMillis': replyMillis,
    'replayMistakes': replayMistakes,
    'shuffleDrill': shuffleDrill,
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
      drillLimit: number('drillLimit', 10, 0, 1000),
      replyMillis: number('replyMillis', 700, 200, 2000),
      replayMistakes: value['replayMistakes'] is bool
          ? value['replayMistakes'] as bool
          : true,
      shuffleDrill: value['shuffleDrill'] is bool
          ? value['shuffleDrill'] as bool
          : false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrainingOptions &&
      learnLimit == other.learnLimit &&
      reviewLimit == other.reviewLimit &&
      drillLimit == other.drillLimit &&
      replyMillis == other.replyMillis &&
      replayMistakes == other.replayMistakes &&
      shuffleDrill == other.shuffleDrill;

  @override
  int get hashCode => Object.hash(
    learnLimit,
    reviewLimit,
    drillLimit,
    replyMillis,
    replayMistakes,
    shuffleDrill,
  );
}
