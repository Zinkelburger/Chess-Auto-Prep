import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'engine.dart';
import 'hivemind_engine.dart';
import 'hivemind_install.dart';
import 'uci_engine.dart';
import 'uci_process.dart';

sealed class EngineStart {
  const EngineStart();
}

final class Started extends EngineStart {
  const Started(this.engine);

  final Engine engine;
}

final class StartFailed extends EngineStart {
  const StartFailed(this.reason);

  /// A sentence for the user.
  final String reason;
}

/// Owns every engine process the app starts and ends them all on
/// [dispose]. One per app; nothing else spawns an engine.
final class EngineSupervisor {
  final _running = <EngineProcess>{};

  /// Set once the app is on its way out: an engine that finishes starting
  /// after that is quit at once rather than kept.
  bool _disposed = false;

  /// Process ids of the engines alive right now. Only the tests and the
  /// exit harness ask: the app never addresses an engine by its pid.
  Iterable<int> get pids => _running.map((engine) => engine.pid);

  /// [patience] is how long the handshake may take; a binary that is not a
  /// UCI engine is killed after it.
  Future<EngineStart> start(
    String executable, {
    Map<String, String> options = const {},
    Duration patience = const Duration(seconds: 10),
  }) async {
    final name = p.basename(executable);
    final SpawnedProcess process;
    try {
      process = await SpawnedProcess.start(executable);
    } on ProcessException catch (e) {
      log.e('start $name', e.message);
      return StartFailed('Could not start $name: ${e.message}');
    }
    try {
      final engine = await UciEngine.start(
        process,
        options: options,
        patience: patience,
      );
      if (!_keep(engine)) return const StartFailed('The app is closing.');
      return Started(engine);
    } on TimeoutException {
      await process.kill();
      log.e('start $name', 'no uciok; stderr: ${process.recentErrors}');
      return StartFailed('$name did not answer as a UCI engine');
    } on EngineFailure catch (e) {
      final said = process.recentErrors.join(' ');
      log.e('start $name', '$e; stderr: ${process.recentErrors}');
      return StartFailed('$name failed to start: ${e.message}. $said'.trim());
    }
  }

  /// Hivemind from its installed [files], limited to [cores] where the
  /// platform lets a process be held to some of them (Linux).
  Future<HivemindStart> startHivemind(
    HivemindFiles files, {
    required int cores,
    Duration patience = const Duration(seconds: 90),
  }) async {
    final SpawnedProcess process;
    try {
      process = await SpawnedProcess.start(
        files.executable,
        // Named from the engine's own folder: on Windows the support folder
        // has spaces in it, and a bare file name survives any quoting.
        arguments: ['--model', p.basename(files.model)],
        workingDirectory: files.directory,
        environment: hivemindEnvironment(files.directory, Platform.environment),
      );
    } on ProcessException catch (e) {
      log.e('start the bughouse engine', e.message);
      return HivemindStartFailed(
        'Could not start the bughouse engine: ${e.message}',
      );
    }
    final engine = await HivemindProcess.start(
      process,
      options: const {'Hash': '256', 'BatchSize': '8'},
      patience: patience,
    );
    if (engine == null) {
      final said = process.recentErrors.join(' ');
      final code = await process.exitCode
          .then<int?>((code) => code)
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      log.e('start the bughouse engine', 'no uciok; exit $code; stderr: $said');
      return HivemindStartFailed(
        [
          'The bughouse engine did not start.',
          ?hivemindExitReason(code),
          said,
        ].where((part) => part.isNotEmpty).join(' '),
      );
    }
    if (!_keep(engine)) return const HivemindStartFailed('The app is closing.');
    await limitCores(process.pid, cores);
    return HivemindStarted(engine);
  }

  /// Keeps [engine] to end on the way out; answers false, having quit it,
  /// when the way out has already begun.
  bool _keep(EngineProcess engine) {
    if (_disposed) {
      unawaited(engine.quit());
      return false;
    }
    _running.add(engine);
    unawaited(engine.exited.then((_) => _running.remove(engine)));
    return true;
  }

  /// Quits every engine, killing any that has not left within two seconds.
  Future<void> dispose() {
    _disposed = true;
    return Future.wait(_running.toList().map((engine) => engine.quit()));
  }
}

/// What Hivemind is started with besides this process's environment: where
/// its ONNX Runtime library is — beside it, in [directory] — and on Windows a
/// PATH cut to that folder and the system's, so no stray 32-bit
/// `MSVCP140.dll` on the user's PATH is loaded ahead of the one it ships.
Map<String, String> hivemindEnvironment(
  String directory,
  Map<String, String> inherited,
) {
  if (Platform.isWindows) {
    final root = inherited['SystemRoot'] ?? r'C:\Windows';
    // Windows names are case-insensitive but the block is a list: reuse the
    // spelling the parent has, or two PATHs would race.
    final key = inherited.keys.firstWhere(
      (name) => name.toLowerCase() == 'path',
      orElse: () => 'PATH',
    );
    return {
      key: [directory, p.join(root, 'System32'), root].join(';'),
    };
  }
  final key = Platform.isMacOS ? 'DYLD_LIBRARY_PATH' : 'LD_LIBRARY_PATH';
  final existing = inherited[key];
  return {
    key: existing == null || existing.isEmpty
        ? directory
        : '$directory:$existing',
  };
}

/// What a Windows loader failure means, in words, for an engine that exited
/// with [code] before it could say anything; null for any other exit.
String? hivemindExitReason(int? code) {
  if (code == null) return null;
  // Windows reports an NTSTATUS as a negative 32-bit exit code.
  final status = code & 0xFFFFFFFF;
  return switch (status) {
    0xC0000135 =>
      'Windows could not find a library it needs (exit 0xC0000135); '
          'installing the Microsoft Visual C++ runtime fixes this.',
    0xC000007B => 'Windows refused to load one of its files (exit 0xC000007B).',
    0xC000001D =>
      'This processor lacks an instruction the engine needs '
          '(exit 0xC000001D).',
    0xC0000005 => 'The engine crashed as it started (exit 0xC0000005).',
    _ => null,
  };
}

/// Holds every thread of [pid] to the first [cores] CPUs this process may
/// use, on Linux; elsewhere the engine chooses. A failure is a log line:
/// the engine still runs, on more cores than asked.
Future<void> limitCores(int pid, int cores) async {
  if (!Platform.isLinux) return;
  try {
    final status = await File('/proc/self/status').readAsString();
    final allowed = RegExp(
      r'^Cpus_allowed_list:\s*(.+)$',
      multiLine: true,
    ).firstMatch(status)?.group(1);
    if (allowed == null) return;
    final cpus = cpuList(allowed);
    final chosen = cpus.take(cores.clamp(1, cpus.length)).join(',');
    final result = await Process.run('taskset', [
      '--all-tasks',
      '--pid',
      '--cpu-list',
      chosen,
      '$pid',
    ]);
    if (result.exitCode != 0) {
      log.w('limit the bughouse engine to $cores cores', result.stderr);
    }
  } on Object catch (error) {
    log.w('limit the bughouse engine to $cores cores', error);
  }
}

/// `0-3,8,10-11` → 0, 1, 2, 3, 8, 10, 11.
List<int> cpuList(String list) => [
  for (final part in list.trim().split(','))
    if (part.split('-') case [final from, ...final rest])
      for (
        var cpu = int.parse(from.trim());
        cpu <= int.parse((rest.isEmpty ? from : rest.first).trim());
        cpu++
      )
        cpu,
];
