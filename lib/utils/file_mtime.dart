/// File mtime helper for "don't persist if the source PGN changed mid-job".
library;

import 'dart:io';

Future<DateTime?> fileModifiedOrNull(String path) async {
  try {
    return await File(path).lastModified();
  } catch (_) {
    return null;
  }
}

bool sameMtime(DateTime? a, DateTime? b) =>
    a != null && b != null && a.isAtSameMomentAs(b);
