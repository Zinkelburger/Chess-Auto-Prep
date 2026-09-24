import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../chess/bughouse/hivemind.dart';
import '../chess/bughouse/table.dart';
import '../diagnostics/log.dart';
import '../engines/engine_supervisor.dart';
import '../engines/hivemind_engine.dart';
import '../storage/atomic_write.dart';
import 'environment.dart';

/// `--self-test-bughouse=<report.json>`: the bughouse engine installed and
/// started exactly as the Bughouse lab would, in this user's own support
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
    final started = await launchHivemind(
      support: support,
      engines: engines,
      cores: 2,
    );
    switch (started) {
      case HivemindStartFailed(:final reason):
        report['failure'] = reason;
      case HivemindStarted(:final engine):
        final answer = await engine.search((
          position: TablePosition.initial,
          team: Team.ab,
          maySit: false,
          mustMove: MustMove.either,
          lines: 1,
          budget: const NodeBudget(64),
        ));
        switch (answer) {
          case HivemindFailed(:final reason):
            report['failure'] = reason;
          case HivemindSearched(:final best):
            report['best'] = best == null
                ? null
                : '(${best.one ?? 'pass'},${best.two ?? 'pass'})';
            ok = best != null;
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
