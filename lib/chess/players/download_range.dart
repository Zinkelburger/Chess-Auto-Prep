import '../tactics/game_ids.dart';

/// One saved download choice. Months fetch every matching game in the period;
/// a count fetches that many matching recent games, across archive boundaries.
final class PlayerDownloadRange {
  const PlayerDownloadRange({
    this.max = 500,
    this.months,
    this.speeds = const {'blitz', 'rapid', 'classical', 'correspondence'},
  });
  final int max;
  final int? months;
  final Set<String> speeds;
  DateTime? since(DateTime now) =>
      months == null ? null : DateTime(now.year, now.month - months! + 1);
  Map<String, Object?> get json => {
    'max': max,
    'months': months,
    'speeds': speeds.toList(),
  };
  factory PlayerDownloadRange.from(Object? value) {
    if (value is! Map) return const PlayerDownloadRange();
    return PlayerDownloadRange(
      max: (value['max'] as int? ?? 500).clamp(1, 10000),
      months: (value['months'] as int?)?.clamp(1, 120),
      speeds:
          (value['speeds'] as List? ??
                  const ['blitz', 'rapid', 'classical', 'correspondence'])
              .whereType<String>()
              .toSet(),
    );
  }

  /// Whether a downloaded game is one this range asked for: played in the
  /// period and of a chosen time control, read off its headers
  /// ([timeClassIn]). A game whose time control cannot
  /// be told ([TimeClass.unknown]) is kept, as no choice here would fetch it.
  bool keeps(String text, DateTime now) {
    final date = DateTime.tryParse(
      playedAt(text).split(' ').first.replaceAll('.', '-'),
    );
    final cutoff = since(now);
    if (cutoff != null && (date == null || date.isBefore(cutoff))) return false;
    final speed = timeClassIn(text);
    return speed == TimeClass.unknown || speeds.contains(speed.name);
  }
}
