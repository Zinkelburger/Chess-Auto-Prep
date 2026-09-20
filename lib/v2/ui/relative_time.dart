import 'package:intl/intl.dart';

/// How long ago [when] was, in the words the old app uses: `just now` under a
/// minute, then `5m ago`, `4h ago`, `3d ago`, and a date once a week has
/// passed. A time in the future reads as `just now`, because a clock that is
/// a minute out should not say `in 43 seconds`.
///
/// The date is formatted by `intl` without initialising locale data, so it
/// falls back to `en_US`. `v2` is English-only, which is the same choice the
/// plain strings in every widget make.
String relativeTime(DateTime when, {DateTime? now}) {
  final since = (now ?? DateTime.now()).difference(when);
  if (since.inMinutes < 1) return 'just now';
  if (since.inHours < 1) return '${since.inMinutes}m ago';
  if (since.inDays < 1) return '${since.inHours}h ago';
  if (since.inDays < 7) return '${since.inDays}d ago';
  return DateFormat.yMMMd().format(when.toLocal());
}
