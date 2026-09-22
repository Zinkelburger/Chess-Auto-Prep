/// When a repertoire line comes back: SM-2, as the old app schedules it, over
/// the rows of `repertoire_reviews.csv` that both apps read and write.
///
/// A line's row carries an *ease* — how much its interval stretches on each
/// Good, higher is easier, 2.5 to start, kept within 1.3–3.0 — and an interval
/// in days. Rating a line moves both:
///
/// | Rating | Ease  | Interval, first time | Interval after that       |
/// |--------|-------|----------------------|---------------------------|
/// | Again  | −0.20 | 0 (due again now)    | 0                         |
/// | Hard   | −0.15 | 1 day                | max(days + 1, days × 1.2) |
/// | Good   |   —   | 1 day                | days × ease               |
/// | Easy   | +0.15 | 3 days               | days × ease × 1.3         |
///
/// "First time" is any interval under a day, so a line after an Again starts
/// over. Intervals stop at a year and, above two days, move by up to ±5% (at
/// least a day) so lines learned together stop coming back together. A line
/// at 10 days with ease 2.5 rated Good comes back in 25 days, give or take
/// one.
library;

import 'dart:math';

/// A line of one chapter, as the progress files name it: the chapter file's
/// path — the files' `repertoire_id` — and the line's id within it.
typedef LineKey = ({String source, String id});

/// How well the user knew a line, as `last_rating` spells it.
enum Rating { again, hard, good, easy }

const startEase = 2.5;
const minEase = 1.3;
const maxEase = 3.0;
const maxIntervalDays = 365.0;

/// One row of `repertoire_reviews.csv`.
final class Review {
  const Review({
    required this.key,
    required this.lineName,
    this.ease = startEase,
    this.intervalDays = 0,
    this.due,
    this.lastRating = '',
    this.lastReviewed,
    this.passes = 0,
    this.fails = 0,
    this.excluded = false,
  });

  final LineKey key;

  /// The name the line had when the row was written; the files keep it so a
  /// person reading them can tell the rows apart. Nothing looks it up.
  final String lineName;

  /// The CSV's `difficulty` column, which has always held the ease.
  final double ease;
  final double intervalDays;
  final DateTime? due;

  /// A [Rating]'s name, or empty for a line never rated: an untrained line.
  final String lastRating;
  final DateTime? lastReviewed;

  /// Completions without a mistake and with one, kept apart from the
  /// schedule so resetting a line does not forget how it has gone.
  final int passes;
  final int fails;

  /// Left out of every queue and count; its history is kept.
  final bool excluded;

  bool get untrained => lastRating.isEmpty;

  /// Whether a trained line is due at [now]. An untrained line is never due:
  /// it is learned, not reviewed.
  bool dueAt(DateTime now) {
    final due = this.due;
    return !untrained && (due == null || !due.isAfter(now));
  }

  Review copyWith({
    String? lineName,
    double? ease,
    double? intervalDays,
    DateTime? due,
    String? lastRating,
    DateTime? lastReviewed,
    int? passes,
    int? fails,
    bool? excluded,
  }) => Review(
    key: key,
    lineName: lineName ?? this.lineName,
    ease: ease ?? this.ease,
    intervalDays: intervalDays ?? this.intervalDays,
    due: due ?? this.due,
    lastRating: lastRating ?? this.lastRating,
    lastReviewed: lastReviewed ?? this.lastReviewed,
    passes: passes ?? this.passes,
    fails: fails ?? this.fails,
    excluded: excluded ?? this.excluded,
  );

  @override
  bool operator ==(Object other) =>
      other is Review &&
      other.key == key &&
      other.lineName == lineName &&
      other.ease == ease &&
      other.intervalDays == intervalDays &&
      other.due == due &&
      other.lastRating == lastRating &&
      other.lastReviewed == lastReviewed &&
      other.passes == passes &&
      other.fails == fails &&
      other.excluded == excluded;

  @override
  int get hashCode => Object.hash(
    key,
    lineName,
    ease,
    intervalDays,
    due,
    lastRating,
    lastReviewed,
    passes,
    fails,
    excluded,
  );
}

/// [review] after the user rated its line [rating] at [now]. [clean] is
/// whether the line went without a mistake; [jitter], in −1..1, spreads the
/// interval (see the table above).
Review rated(
  Review review,
  Rating rating, {
  required DateTime now,
  required bool clean,
  required double jitter,
}) {
  final ease = _easeAfter(review.ease.clamp(minEase, maxEase), rating);
  final days = _spread(_interval(review.intervalDays, rating, ease), jitter);
  return review.copyWith(
    ease: ease,
    intervalDays: days,
    due: now.add(_days(days)),
    lastRating: rating.name,
    lastReviewed: now,
    passes: clean ? review.passes + 1 : review.passes,
    fails: clean ? review.fails : review.fails + 1,
  );
}

/// The interval [rating] would give [review], unspread: what a rating button
/// says it schedules.
double intervalFor(Review review, Rating rating) => _interval(
  review.intervalDays,
  rating,
  _easeAfter(review.ease.clamp(minEase, maxEase), rating),
);

/// [review] put on the schedule without being trained: the user says they
/// know the line. The [nth] line marked at once comes back 1 + (n mod 5) / 2
/// days out, so a hundred lines marked together arrive over five days.
Review markedKnown(Review review, {required DateTime now, required int nth}) {
  final days = 1.0 + (nth % 5) * 0.5;
  return review.copyWith(
    intervalDays: days,
    due: now.add(_days(days)),
    lastRating: Rating.good.name,
    lastReviewed: now,
  );
}

/// [review] untrained again, keeping its ease, its tallies and whether it is
/// excluded.
Review markedUnknown(Review review) => Review(
  key: review.key,
  lineName: review.lineName,
  ease: review.ease,
  passes: review.passes,
  fails: review.fails,
  excluded: review.excluded,
);

double _easeAfter(double ease, Rating rating) => switch (rating) {
  Rating.again => max(minEase, ease - 0.20),
  Rating.hard => max(minEase, ease - 0.15),
  Rating.good => ease,
  Rating.easy => min(maxEase, ease + 0.15),
};

double _interval(double current, Rating rating, double ease) {
  final first = current < 1;
  final next = switch (rating) {
    Rating.again => 0.0,
    Rating.hard => first ? 1.0 : max(current + 1, current * 1.2),
    Rating.good => first ? 1.0 : current * ease,
    Rating.easy => first ? 3.0 : current * ease * 1.3,
  };
  return min(next, maxIntervalDays);
}

double _spread(double days, double jitter) {
  if (days < 2) return days;
  final spread = max(1.0, days * 0.05);
  return (days + jitter * spread).clamp(1.0, maxIntervalDays);
}

Duration _days(double days) =>
    Duration(milliseconds: (days * Duration.millisecondsPerDay).round());
