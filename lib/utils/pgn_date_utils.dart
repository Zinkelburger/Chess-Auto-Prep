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
