/// Human-friendly rendering of PGN `Date` headers.
///
/// PGN dates are `YYYY.MM.DD` with `??` for unknown fields (e.g.
/// `1983.??.??`). Showing the placeholders is confusing, so render only the
/// fields that are actually known:
///   `1983.??.??` → `1983`
///   `1983.05.??` → `May 1983`
///   `1983.05.17` → `May 17, 1983`
/// Fully unknown dates render as an empty string so callers can omit them.
library;

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Sortable when-was-this-played key for a game, from its PGN headers.
///
/// Prefers `UTCDate`/`UTCTime` (what Lichess and Chess.com both write) over the
/// local `Date`/`Time`, and renders a zero-padded `YYYY.MM.DD HH:MM:SS` so a
/// plain string compare orders games chronologically. Returns `''` when the
/// headers carry no usable date — callers sort those last, since a game with no
/// date has no place on a timeline.
String pgnHeaderSortKey(Map<String, String> headers) {
  final rawDate = headers['UTCDate'] ?? headers['Date'] ?? '';
  final dateParts = rawDate.trim().split(RegExp(r'[./-]'));
  String? pad(int index, int min, int max, int width) {
    if (index >= dateParts.length) return null;
    final v = int.tryParse(dateParts[index]);
    if (v == null || v < min || v > max) return null;
    return v.toString().padLeft(width, '0');
  }

  final year = pad(0, 1, 9999, 4);
  if (year == null) return '';
  final month = pad(1, 1, 12, 2) ?? '00';
  final day = pad(2, 1, 31, 2) ?? '00';

  // Time is a bonus: same-day games only order correctly when it is present,
  // and a missing one must not disturb the date compare — hence the 00:00:00.
  final rawTime = (headers['UTCTime'] ?? headers['Time'] ?? '').trim();
  final timeParts = rawTime.split(':');
  String field(int index, int max) {
    if (index >= timeParts.length) return '00';
    final v = int.tryParse(timeParts[index]);
    if (v == null || v < 0 || v > max) return '00';
    return v.toString().padLeft(2, '0');
  }

  return '$year.$month.$day '
      '${field(0, 23)}:${field(1, 59)}:${field(2, 59)}';
}

String formatPgnDate(String? raw) {
  if (raw == null) return '';
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';

  final parts = trimmed.split(RegExp(r'[./-]'));
  int? fieldAt(int i, int min, int max) {
    if (i >= parts.length) return null;
    final v = int.tryParse(parts[i]);
    if (v == null || v < min || v > max) return null;
    return v;
  }

  final year = fieldAt(0, 1, 9999);
  if (year == null) return '';
  final month = fieldAt(1, 1, 12);
  if (month == null) return '$year';
  final day = fieldAt(2, 1, 31);
  final monthName = _monthNames[month - 1];
  if (day == null) return '$monthName $year';
  return '$monthName $day, $year';
}
