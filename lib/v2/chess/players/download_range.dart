import '../pgn/game_text.dart';
import '../pgn/pgn_reader.dart';
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
  bool keeps(String text, DateTime now) {
    final date = DateTime.tryParse(
      playedAt(text).split(' ').first.replaceAll('.', '-'),
    );
    final cutoff = since(now);
    if (cutoff != null && (date == null || date.isBefore(cutoff))) return false;
    final tags = readGame(text).tags;
    return speeds.contains(
      timeControlSpeed(tagValue(tags, 'TimeControl') ?? ''),
    );
  }
}

String timeControlSpeed(String control) {
  if (control.contains('/')) return 'correspondence';
  final parts = control.split('+');
  final base = int.tryParse(parts.first) ?? 0;
  if (base == 0) return 'other';
  final seconds =
      base + 40 * (parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
  return seconds < 180
      ? 'bullet'
      : seconds < 600
      ? 'blitz'
      : seconds < 1800
      ? 'rapid'
      : 'classical';
}
