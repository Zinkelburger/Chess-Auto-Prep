import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'engine.dart';
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
  final _running = <UciEngine>{};

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
      _running.add(engine);
      unawaited(engine.exited.then((_) => _running.remove(engine)));
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

  /// Quits every engine, killing any that has not left within two seconds.
  Future<void> dispose() =>
      Future.wait(_running.toList().map((engine) => engine.quit()));
}
