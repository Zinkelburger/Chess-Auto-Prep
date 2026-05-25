import 'dart:ffi';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

void _ffiInit() {
  if (Platform.isLinux) {
    open.overrideFor(
      OperatingSystem.linux,
      () => DynamicLibrary.open('/lib64/libsqlite3.so.0'),
    );
  }
}

/// Initialise FFI SQLite for unit tests (desktop CI / local dev).
Future<void> initEvalTestSqlite() async {
  _ffiInit();
  sqfliteFfiInit();
  databaseFactory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
}
