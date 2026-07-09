/// Atomic text-file writes, shared by every service that persists user data.
///
/// Writes to a hidden temp file in the target directory, then renames over
/// the destination so readers never observe a half-written file. Rename is
/// atomic on POSIX filesystems; where rename-over-existing fails the
/// destination is deleted first and the rename retried.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Isolate-safe (no global state), so background isolates can call it too.
Future<void> writeTextFileAtomically(File target, String content) async {
  final parent = target.parent;
  if (!await parent.exists()) {
    await parent.create(recursive: true);
  }
  final tmp = File(
    p.join(
      parent.path,
      '.${p.basename(target.path)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    ),
  );
  await tmp.writeAsString(content, flush: true);
  try {
    await tmp.rename(target.path);
  } on FileSystemException {
    if (await target.exists()) {
      await target.delete();
    }
    await tmp.rename(target.path);
  }
}
