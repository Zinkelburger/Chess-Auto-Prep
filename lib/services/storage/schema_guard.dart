import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Refuse a downgrade before touching schema or journal mode. This is not
/// corruption: callers must never quarantine or rebuild a newer database.
int requireSupportedSchema(Database db, int supported, String label) {
  final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
  if (version > supported) {
    throw StateError(
      '$label was written by a newer Chess Auto Prep version '
      '(schema $version; this app supports $supported). Reinstall the newer '
      'app to use it. The database has been left intact.',
    );
  }
  return version;
}

/// SQLite creates a consistent snapshot including committed WAL contents.
/// Keep the first pre-migration copy; retries must not replace that recovery
/// point with a partially changed database. Rebuildable caches don't use this.
void backupBeforeSchemaUpgrade(Database db, String path, int target) {
  if (path == ':memory:') return;
  final tables = db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  );
  if (tables.isEmpty) return;
  final backup = File('$path.before-schema-$target.sqlite');
  if (backup.existsSync()) return;
  final temporary = File('${backup.path}.pending-$pid');
  try {
    db.execute('VACUUM INTO ?', [temporary.path]);
    // VACUUM INTO closes its output but does not fsync it itself.
    final output = temporary.openSync(mode: FileMode.append);
    try {
      output.flushSync();
    } finally {
      output.closeSync();
    }
    temporary.renameSync(backup.path);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}
