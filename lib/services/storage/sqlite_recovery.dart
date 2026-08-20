/// Opening a SQLite file that might be damaged.
///
/// The app owns two databases it can rebuild: `master_games.db` (a TWIC
/// cache, re-synced from the network) and `app_games.db` (games re-imported
/// from the platforms, plus the tactics archive).  Neither is worth wedging
/// the app over.  A damaged file used to mean every call site that opens it
/// throws forever, with no way out that does not involve the user finding
/// the support directory and deleting a file by hand — so [openSqlite]
/// quarantines the bad file and starts a fresh one instead.
///
/// Only the UI-owned service connections go through this.  Importer
/// isolates open the same paths directly and are left to fail: they run
/// while the service connection is open, and having a background isolate
/// rename the file out from under it would turn one recoverable problem
/// into two.
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../utils/log.dart';

/// Whether [e] means "this file is not a usable database".
///
/// `SQLITE_CORRUPT` is a damaged page image; `SQLITE_NOTADB` is what a
/// truncated or half-written file looks like — the plausible outcome of a
/// power cut during a master-games import, which runs with
/// `synchronous = OFF` on purpose.  Every other code (permissions, disk
/// full, busy, read-only filesystem) is environmental or transient:
/// starting over on a fresh file would not fix it and would throw away data
/// that is almost certainly intact.
bool isCorruptDatabase(Object e) =>
    e is SqliteException &&
    (e.resultCode == SqlError.SQLITE_CORRUPT ||
        e.resultCode == SqlError.SQLITE_NOTADB);

/// Open the database at [path] with [open], recovering once from a corrupt
/// file by moving it aside and letting [open] create a new one.
///
/// [open] must be the whole open-and-migrate sequence, since damage often
/// only surfaces when the schema is first read.  [label] names the database
/// in the log.  Errors that are not corruption propagate untouched.
T openSqlite<T>(String path, T Function() open, {required String label}) {
  try {
    return open();
  } catch (e) {
    if (!isCorruptDatabase(e)) rethrow;
    final moved = quarantineDatabase(path);
    log.e(
      '$label: $path is corrupt ($e); moved aside'
      '${moved == null ? '' : ' to $moved'} and starting a new one',
    );
    return open();
  }
}

/// Rename [path] and its WAL sidecars aside, returning the new path (null
/// if nothing could be moved).  The file is kept, never deleted — it may
/// still be salvageable with `sqlite3 .recover`, and it is the user's data.
String? quarantineDatabase(String path) {
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final target = '$path.corrupt-$stamp';
  String? moved;
  for (final suffix in const ['', '-wal', '-shm']) {
    final file = File('$path$suffix');
    if (!file.existsSync()) continue;
    try {
      file.renameSync('$target$suffix');
      if (suffix.isEmpty) moved = target;
    } catch (e) {
      // A sidecar that will not move is not fatal: SQLite discards a WAL
      // whose database is gone.  The main file failing to move is, and the
      // retried open will surface it.
      log.w('Could not move $path$suffix aside: $e');
    }
  }
  return moved;
}
