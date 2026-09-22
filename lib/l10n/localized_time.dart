import 'package:intl/intl.dart';

import '../utils/time_format.dart';
import 'generated/app_localizations.dart';

String formatLocalizedTimeAgo(
  AppLocalizations messages,
  DateTime when, {
  DateTime? now,
}) => switch (timeAgoValue(when, now: now)) {
  (TimeAgoUnit.now, _) => messages.justNow,
  (TimeAgoUnit.minutes, final count) => messages.minutesAgo(count),
  (TimeAgoUnit.hours, final count) => messages.hoursAgo(count),
  (TimeAgoUnit.days, final count) => messages.daysAgo(count),
  (TimeAgoUnit.date, _) => DateFormat.yMMMd(
    messages.localeName,
  ).format(when.toLocal()),
};
