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
import 'v2/diagnostics/log.dart';
import 'v2/storage/log_file.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installAgentDriver();
  final documents = await getApplicationDocumentsDirectory();
  final support = await getApplicationSupportDirectory();
  log.install(await LogFile(Directory(p.join(support.path, 'logs'))).open());
  log.i('start');
  runApp(ChessAutoPrepV2(documents: documents, support: support));
}
