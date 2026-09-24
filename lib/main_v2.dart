// The v2 entry point: `flutter run -t lib/main_v2.dart`.
//
// `debug/agent_driver.dart` is headless-test tooling shared with the old
// app, not application code; it is the one import from outside `lib/v2/`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'debug/agent_driver.dart';
import 'v2/app/app.dart';
import 'v2/app/error_log.dart';
import 'v2/app/self_test.dart';
import 'v2/diagnostics/log.dart';
import 'v2/storage/log_file.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  installAgentDriver();
  final documents = await getApplicationDocumentsDirectory();
  final support = await getApplicationSupportDirectory();
  final logFolder = Directory(p.join(support.path, 'logs'));
  final logFile = LogFile(logFolder);
  await _installLog(logFile);
  installErrorLog();
  log.i('start');
  if (selfTestReport(args) case final report?) {
    await runBughouseSelfTest(support: support, reportPath: report);
  }
  runApp(
    ChessAutoPrepV2(
      documents: documents,
      support: support,
      logFolder: logFolder,
      closeLog: logFile.close,
    ),
  );
}

/// A support folder that cannot be written must not keep the app shut: the
/// console still carries warnings and errors, and this one says why the
/// file does not.
Future<void> _installLog(LogFile file) async {
  try {
    log.install(await file.open());
  } catch (e) {
    // ignore: avoid_print
    print('Could not open ${file.file.path}: $e');
  }
}
