// The v2 entry point: `flutter run -t lib/main_v2.dart`.
//
// `debug/` supplies the optional headless driver and packaged-app checks.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'debug/agent_driver.dart';
import 'debug/desktop_self_test.dart';
import 'v2/app/app.dart';
import 'v2/app/error_log.dart';
import 'v2/app/self_test.dart';
import 'v2/diagnostics/log.dart';
import 'v2/storage/log_file.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  installAgentDriver();
  if (desktopReportPath(args) case final report?) {
    await runDesktopSelfTest(report);
  }
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
