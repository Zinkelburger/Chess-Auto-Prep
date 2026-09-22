import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Where the lock for [directory] lives, worked out the way the old app
/// works it out (`lib/utils/file_operation_lock.dart`): FNV-1a of the
/// resolved path under the system temporary folder. Written out again here
/// so a change to either side of the protocol fails a test rather than a
/// user's save.
Future<String> lockPathOf(Directory directory) async {
  final key = p.normalize(await directory.resolveSymbolicLinks());
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(key)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return p.join(
    Directory.systemTemp.path,
    'chess-auto-prep-file-locks',
    '${hash.toRadixString(16).padLeft(16, '0')}.sqlite3',
  );
}
