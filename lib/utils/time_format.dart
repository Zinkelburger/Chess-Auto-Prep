/// One home for every "how long?" and "how long ago?" string in the app.
///
/// These used to be re-derived at each call site — four hand-rolled "time ago"
/// ladders that disagreed about the first minute (`0m ago` vs `just now`) and
/// about anything older than a week (`412d ago` vs a date), and three elapsed
/// formatters that differed only in whether seconds were zero-padded. The
/// strings are chrome, so nobody noticed them drifting; the fix is that there
/// is now one of each.
///
/// Three roles, because they answer three different questions:
///
/// * [formatTimeAgo] — when did this happen? (a timestamp, in the past)
/// * [formatTimeUntil] — when does this fall due? (a timestamp, in the future)
/// * [formatCompactDuration] — how long did this take? (a run, a job, a game)
/// * [formatCoarseDuration] — how much longer? (a multi-hour transfer's ETA,
///   where seconds are noise)
library;

/// How long ago [when] was: `just now`, `4m ago`, `3h ago`, `5d ago`, and then
/// a bare `M/D` date once it is more than a week old.
///
/// A week is the cut-off because "9d ago" and "23d ago" read the same at a
/// glance — past that point the date itself is the more useful string.
///
/// [now] is a parameter so tests do not have to run at a particular instant.
/// A [when] in the future (a clock skew, a file written by another machine)
/// reads as `just now` rather than a negative count.
String formatTimeAgo(DateTime when, {DateTime? now}) =>
    switch (timeAgoValue(when, now: now)) {
      (TimeAgoUnit.now, _) => 'just now',
      (TimeAgoUnit.minutes, final count) => '${count}m ago',
      (TimeAgoUnit.hours, final count) => '${count}h ago',
      (TimeAgoUnit.days, final count) => '${count}d ago',
      (TimeAgoUnit.date, _) => '${when.month}/${when.day}',
    };

enum TimeAgoUnit { now, minutes, hours, days, date }

/// Shared thresholds, independent of presentation and locale.
(TimeAgoUnit, int) timeAgoValue(DateTime when, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(when);
  if (diff.inMinutes < 1) return (TimeAgoUnit.now, 0);
  if (diff.inHours < 1) return (TimeAgoUnit.minutes, diff.inMinutes);
  if (diff.inDays < 1) return (TimeAgoUnit.hours, diff.inHours);
  if (diff.inDays < 7) return (TimeAgoUnit.days, diff.inDays);
  return (TimeAgoUnit.date, 0);
}

/// How long until [when]: `now`, `in 12m`, `in 5h`, `in 3d`, and then a bare
/// `M/D` date once it is more than a week out.
///
/// The mirror of [formatTimeAgo], and the reason it exists: the training
/// panel's "Next review" line was running a *past*-tense formatter over a
/// *future* date, so a review due in three days read `-4320m ago`. A due date
/// that has already passed reads `now`, which is what "due" means.
///
/// [now] is a parameter so tests do not have to run at a particular instant.
String formatTimeUntil(DateTime when, {DateTime? now}) {
  final diff = when.difference(now ?? DateTime.now());
  if (diff.inMinutes < 1) return 'now';
  if (diff.inHours < 1) return 'in ${diff.inMinutes}m';
  if (diff.inDays < 1) return 'in ${diff.inHours}h';
  if (diff.inDays < 7) return 'in ${diff.inDays}d';
  return '${when.month}/${when.day}';
}

/// How long something took, as short as it can be while staying sortable by
/// eye: `1h 12m`, `4m 09s`, `38s`.
///
/// Seconds are zero-padded so a column of run times lines up; minutes and
/// hours are not, because they lead the string.
String formatCompactDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  if (d.inMinutes > 0) {
    return '${d.inMinutes}m '
        '${d.inSeconds.remainder(60).toString().padLeft(2, '0')}s';
  }
  return '${d.inSeconds}s';
}

/// `3 h 40 min`, `12 min`, `45 s` — coarse on purpose.
///
/// This is the shape for download and import ETAs, where the estimate itself
/// is only good to the nearest minute: showing seconds off a multi-hour
/// transfer implies a precision the number does not have. Anything past two
/// days collapses to whole days for the same reason.
String formatCoarseDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  if (hours < 48) {
    return minutes == 0 ? '$hours h' : '$hours h $minutes min';
  }
  return '${d.inDays} days';
}

/// Human-readable label for a review interval in days.
String formatReviewInterval(double intervalDays) {
  // "Again" schedules zero days on purpose — the line comes back inside the
  // session you are in — and "<1m" reads as a rounding artefact rather than
  // as the promise it is.
  if (intervalDays <= 0) return 'now';
  if (intervalDays < 1 / 24) return '<1m';
  if (intervalDays < 1) return '${(intervalDays * 24).round()}h';
  if (intervalDays < 30) return '${intervalDays.round()}d';
  if (intervalDays < 365) return '${(intervalDays / 30).round()}mo';
  return '${(intervalDays / 365).round()}y';
}
