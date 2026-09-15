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
  final date = _PgnDate.parse(headers['UTCDate'] ?? headers['Date']);
  if (date == null) return '';
  final year = date.year.toString().padLeft(4, '0');
  final month = _twoDigits(date.month);
  final day = _twoDigits(date.day);

  // Time is a bonus: same-day games only order correctly when it is present,
  // and a missing one must not disturb the date compare — hence the 00:00:00.
  final timeParts = (headers['UTCTime'] ?? headers['Time'] ?? '').trim().split(
    ':',
  );
  final hour = _twoDigits(_boundedField(timeParts, 0, 0, 23));
  final minute = _twoDigits(_boundedField(timeParts, 1, 0, 59));
  final second = _twoDigits(_boundedField(timeParts, 2, 0, 59));
  return '$year.$month.$day $hour:$minute:$second';
}

/// [raw] as `1983`, `May 1983` or `May 17, 1983`, whichever fields are known.
String formatPgnDate(String? raw) {
  final date = _PgnDate.parse(raw);
  if (date == null) return '';
  final month = date.month;
  if (month == null) return '${date.year}';
  final monthName = _monthNames[month - 1];
  final day = date.day;
  if (day == null) return '$monthName ${date.year}';
  return '$monthName $day, ${date.year}';
}

/// The known fields of a `YYYY.MM.DD` header; `??` and out-of-range parts
/// read as unknown, and a date with no usable year is no date at all.
class _PgnDate {
  final int year;
  final int? month;
  final int? day;

  const _PgnDate(this.year, this.month, this.day);

  static _PgnDate? parse(String? raw) {
    final parts = (raw ?? '').trim().split(RegExp(r'[./-]'));
    final year = _boundedField(parts, 0, 1, 9999);
    if (year == null) return null;
    return _PgnDate(
      year,
      _boundedField(parts, 1, 1, 12),
      _boundedField(parts, 2, 1, 31),
    );
  }
}

/// `parts[index]` as an integer in `[min, max]`, or null when absent,
/// non-numeric (`??`) or out of range.
int? _boundedField(List<String> parts, int index, int min, int max) {
  if (index >= parts.length) return null;
  final value = int.tryParse(parts[index]);
  if (value == null || value < min || value > max) return null;
  return value;
}

/// Zero-padded to two digits; an unknown field reads `00`.
String _twoDigits(int? value) => (value ?? 0).toString().padLeft(2, '0');
