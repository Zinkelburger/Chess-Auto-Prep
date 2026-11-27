import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../chess/bughouse/table.dart';
import '../diagnostics/log.dart';
import '../engines/engine_supervisor.dart';
import '../engines/hypebeast_engine.dart';
import '../storage/atomic_write.dart';
import 'native_engines.dart';

/// `--self-test-bughouse=<report.json>`: the bughouse engine installed and
/// started exactly as the Bughouse mode would, in this user's own support
/// folder, then asked for one search. The report says what happened; the
/// process ends with 0 when the engine answered and 1 otherwise.
///
/// For an installed build on a machine nobody can watch — the Windows check
/// runs it after a silent install — and for a user asked to send the report.
const selfTestFlag = '--self-test-bughouse=';

/// The report path when [args] ask for the self-test, else null.
String? selfTestReport(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith(selfTestFlag)) return arg.substring(selfTestFlag.length);
  }
  return null;
}

/// Runs the self-test, writes the report to [reportPath] and ends the
/// process.
Future<Never> runBughouseSelfTest({
  required Directory support,
  required String reportPath,
}) async {
  final report = <String, Object?>{
    'os': Platform.operatingSystemVersion,
    'executable': Platform.resolvedExecutable,
    'support': support.path,
    'engineFolder': p.join(support.path, 'bughouse'),
  };
  final engines = EngineSupervisor();
  var ok = false;
  try {
    final started = await launchHypeBeast(support: support, engines: engines);
    switch (started) {
      case HypeBeastStartFailed(:final reason):
        report['failure'] = reason;
      case HypeBeastStarted(:final engine):
        report['engine'] = engine.provenance;
        // Board 1 with the coordinator, as the mode's two-board search.
        final answer = await engine.search((
          position: TablePosition.initial,
          played: null,
          board: BoardNumber.one,
          lines: 1,
          coordination: true,
          threads: 2,
          budget: const NodeBudget(20000),
        ));
        switch (answer) {
          case HypeBeastFailed(:final reason):
            report['failure'] = reason;
          case HypeBeastSearched(:final decision):
            report['best'] = decision?.toString();
            ok = decision?.move != null;
            if (!ok) report['failure'] = 'The engine returned no move.';
        }
        await engine.quit();
    }
  } on Object catch (error) {
    report['failure'] = '$error';
  }
  final folder = Directory(p.join(support.path, 'bughouse'));
  report['files'] = {
    if (folder.existsSync())
      for (final entry in folder.listSync().whereType<File>())
        p.basename(entry.path): entry.lengthSync(),
  };
  report['ok'] = ok;
  log.i('bughouse self-test: ${ok ? 'passed' : report['failure']}');
  await engines.dispose();
  await replaceFile(
    reportPath,
    utf8.encode(const JsonEncoder.withIndent('  ').convert(report)),
  );
  exit(ok ? 0 : 1);
}
