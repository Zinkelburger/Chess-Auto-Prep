import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Initialise FFI SQLite for unit tests (desktop CI / local dev).
/// sqlite3 v3 uses build hooks to bundle the native library automatically,
/// so manual DynamicLibrary overrides are no longer needed.
Future<void> initEvalTestSqlite() async {
  sqfliteFfiInit();
  databaseFactory = createDatabaseFactoryFfi();
}
