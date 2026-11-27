import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'engine.dart';
import 'hypebeast_engine.dart';
import 'hypebeast_install.dart';
import 'uci_engine.dart';
import 'uci_process.dart';

sealed class EngineStart {
  const EngineStart();
}

final class Started extends EngineStart {
  const Started(this.engine, {this.notice});

  final Engine engine;

  /// A sentence for the user when this is not the engine they chose: the
  /// one they chose did not start and this one runs in its place.
  final String? notice;
}

/// What the engine wrote before it failed is in the [EngineTranscript] the
/// caller passed to [EngineSupervisor.start].
final class StartFailed extends EngineStart {
  const StartFailed(this.reason);

  /// A sentence for the user.
  final String reason;
}

/// Why [executable] cannot be run as an engine, found before trying: the
/// mistakes a picked file most often has, each named. Null when it may run;
/// a bare command name is left to the system's search path.
Future<String?> _unrunnable(String executable) async {
  if (!p.isAbsolute(executable)) return null;
  final name = p.basename(executable);
  switch (await FileSystemEntity.type(executable)) {
    case FileSystemEntityType.notFound:
      return '$name is not there: $executable';
    case FileSystemEntityType.directory:
      return '$name is a folder. Choose the engine file inside it.';
    default:
  }
  // Execute bits for owner, group and others: 0o111.
  if (!Platform.isWindows && (await File(executable).stat()).mode & 0x49 == 0) {
    return '$name is not executable. Allow it to run as a program.';
  }
  return null;
}

/// Owns every engine process the app starts and ends them all on
/// [dispose]. One per app; nothing else spawns an engine.
final class EngineSupervisor {
  EngineSupervisor({
    this.closingPatience = const Duration(seconds: 12),
    this.startProcess = Process.start,
  });

  /// How long [dispose] waits for engines to confirm exit. Longer than a
  /// quit that falls back to a kill takes at most, so the warning it logs
  /// means something really did not settle.
  final Duration closingPatience;

  /// How every engine's process is started.
  final ProcessStarter startProcess;

  final _running = <EngineProcess>{};
  final _handshakes = <SpawnedProcess>{};
  final _starts = <Future<void>>{};
  Future<void>? _closing;

  /// Set once the app is on its way out: an engine that finishes starting
  /// after that is quit at once rather than kept.
  bool _disposed = false;

  /// Process ids of the engines alive right now. Only the tests and the
  /// exit harness ask: the app never addresses an engine by its pid.
  Iterable<int> get pids => [
    for (final engine in _running) engine.pid,
    for (final process in _handshakes) process.pid,
  ];

  /// [patience] is how long the handshake may take; a binary that is not a
  /// UCI engine is killed after it. [finitePatience] bounds each fixed-depth
  /// search from its `go`; continuous analysis is uncapped until stopped.
  /// With [advertisedOnly], options the engine does not list are not sent.
  Future<EngineStart> start(
    String executable, {
    Map<String, String> options = const {},
    List<String> arguments = const [],
    Duration patience = const Duration(seconds: 10),
    Duration finitePatience = UciEngine.defaultFinitePatience,
    EngineTranscript? transcript,
    bool advertisedOnly = false,
  }) {
    if (_disposed) {
      return Future.value(const StartFailed('The app is closing.'));
    }
    if (finitePatience <= Duration.zero) {
      return Future.value(
        const StartFailed('The finite search deadline must be positive.'),
      );
    }
    return _own(
      _start(
        executable,
        Map.unmodifiable(options),
        List.unmodifiable(arguments),
        (
          patience: patience,
          finite: finitePatience,
          advertisedOnly: advertisedOnly,
        ),
        transcript ?? EngineTranscript(),
      ),
    );
  }

  Future<EngineStart> _start(
    String executable,
    Map<String, String> options,
    List<String> arguments,
    ({Duration patience, Duration finite, bool advertisedOnly}) limits,
    EngineTranscript transcript,
  ) async {
    final name = p.basename(executable);
    if (await _unrunnable(executable) case final reason?) {
      log.e('start $name', reason);
      return StartFailed(reason);
    }
    final SpawnedProcess process;
    try {
      process = await SpawnedProcess.start(
        executable,
        arguments: arguments,
        transcript: transcript,
        startProcess: startProcess,
      );
    } on ProcessException catch (e) {
      log.e('start $name', e.message);
      return StartFailed('Could not start $name: ${e.message}');
    }
    _trackHandshake(process);
    try {
      if (_disposed) {
        await process.kill();
        return const StartFailed('The app is closing.');
      }
      final engine = await UciEngine.start(
        process,
        options: options,
        patience: limits.patience,
        finitePatience: limits.finite,
        advertisedOnly: limits.advertisedOnly,
      );
      if (!_keep(engine, process)) {
        await engine.quit();
        return const StartFailed('The app is closing.');
      }
      return Started(engine);
    } on TimeoutException catch (e) {
      await process.kill();
      final silence = e.message ?? 'no uciok';
      log.e('start $name', '$silence; stderr: ${process.recentErrors}');
      return StartFailed(
        '$name did not answer as a UCI engine: $silence within '
        '${limits.patience.inSeconds} s',
      );
    } on EngineFailure catch (e) {
      final code = await process.exitCode
          .then<int?>((code) => code)
          .timeout(const Duration(seconds: 1), onTimeout: () => null);
      await process.kill();
      if (_disposed) return const StartFailed('The app is closing.');
      log.e('start $name', '$e; stderr: ${process.recentErrors}');
      return StartFailed(
        '$name crashed while starting'
        '${code == null ? '' : ' (exit code $code)'}',
      );
    } on Object catch (error) {
      await process.kill();
      log.e('start $name', error);
      return StartFailed('$name failed to start: $error');
    }
  }

  /// HypeBeast from its installed [files], its net loaded and proved.
  /// Threads are set per search; the process starts on one.
  Future<HypeBeastStart> startHypeBeast(
    HypeBeastFiles files, {
    Duration patience = const Duration(seconds: 90),
  }) => _disposed
      ? Future.value(const HypeBeastStartFailed('The app is closing.'))
      : _own(_startHypeBeast(files, patience));

  Future<HypeBeastStart> _startHypeBeast(
    HypeBeastFiles files,
    Duration patience,
  ) async {
    final SpawnedProcess process;
    final identity = {
      'engine_sha256': await fileSha256(files.executable),
      'net_sha256': await fileSha256(files.net),
    };
    try {
      if (_disposed) return const HypeBeastStartFailed('The app is closing.');
      process = await SpawnedProcess.start(
        files.executable,
        workingDirectory: files.directory,
        startProcess: startProcess,
      );
    } on Object catch (e) {
      log.e('start the bughouse engine', '$e');
      return HypeBeastStartFailed('Could not start the bughouse engine: $e');
    }
    _trackHandshake(process);
    try {
      if (_disposed) {
        await process.kill();
        return const HypeBeastStartFailed('The app is closing.');
      }
      final HypeBeastProcess? engine;
      try {
        engine = await HypeBeastProcess.start(
          process,
          net: files.net,
          options: const {'Hash': '$hypeBeastHashMb', 'Threads': '1'},
          provenance: identity,
          patience: patience,
        );
      } on EngineFailure catch (failure) {
        log.e(
          'start the bughouse engine',
          '${failure.message} stderr: ${process.recentErrors.join(' ')}',
        );
        return HypeBeastStartFailed(
          'The bughouse engine did not start: ${failure.message}',
        );
      }
      if (engine == null) {
        if (_disposed) return const HypeBeastStartFailed('The app is closing.');
        final said = process.recentErrors.join(' ');
        // Killed already, but a process stuck in the kernel may never end:
        // the exit code is worth a second, not the start's answer.
        final code = await process.exitCode
            .then<int?>((code) => code)
            .timeout(const Duration(seconds: 1), onTimeout: () => null);
        log.e(
          'start the bughouse engine',
          'no uciok; exit $code; stderr: $said',
        );
        return HypeBeastStartFailed(
          [
            'The bughouse engine did not start.',
            ?engineExitReason(code),
            said,
          ].where((part) => part.isNotEmpty).join(' '),
        );
      }
      if (!_keep(engine, process)) {
        await engine.quit();
        return const HypeBeastStartFailed('The app is closing.');
      }
      return HypeBeastStarted(engine);
    } on Object catch (error) {
      await process.kill();
      log.e('start the bughouse engine', error);
      return HypeBeastStartFailed(
        'Could not start the bughouse engine: $error',
      );
    }
  }

  /// A failed handshake may outlive its kill timeout. Keep the process
  /// available to dispose until it exits or ownership transfers in [_keep].
  void _trackHandshake(SpawnedProcess process) {
    _handshakes.add(process);
    process.exitCode.then((_) => _handshakes.remove(process)).ignore();
  }

  /// Transfers a handshaking process to its protocol owner without a gap.
  /// On refusal the starter awaits its quit before its owned future settles.
  bool _keep(EngineProcess engine, SpawnedProcess process) {
    if (_disposed) return false;
    _handshakes.remove(process);
    _running.add(engine);
    unawaited(engine.exited.then((_) => _running.remove(engine)));
    return true;
  }

  /// Holds even a start whose native spawn has not returned. Late arrivals
  /// see [_disposed] and confirm their own cleanup before this future ends.
  Future<T> _own<T>(Future<T> start) {
    late final Future<void> settled;
    settled = start
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _starts.remove(settled));
    _starts.add(settled);
    return start;
  }

  /// Rejects new starts, kills handshakes, and waits up to [closingPatience]
  /// for every accepted start and running engine to confirm exit: a spawn
  /// that never returns must not keep the app from closing. Repeated calls
  /// share that same wait.
  Future<void> dispose() {
    _disposed = true;
    return _closing ??=
        Future.wait([
          for (final process in _handshakes.toList()) process.kill(),
          for (final engine in _running.toList()) engine.quit(),
          ..._starts,
        ]).timeout(
          closingPatience,
          onTimeout: () {
            log.w('close engines', 'not all confirmed exit in time');
            return const [];
          },
        );
  }
}

/// The hash table of each bughouse engine process, in MB.
const hypeBeastHashMb = 128;

final _hashes = <String, ({int size, DateTime modified, String hash})>{};

/// The SHA-256 of the file at [path], recorded with saved bughouse analysis
/// so it says which engine and network made it. Worked out once per file
/// version (size and modification time) rather than on every start. Null
/// when the file cannot be read: provenance is never a reason not to start.
Future<String?> fileSha256(String path) async {
  try {
    final stat = await File(path).stat();
    final known = _hashes[path];
    if (known != null &&
        known.size == stat.size &&
        known.modified == stat.modified) {
      return known.hash;
    }
    final hash = (await sha256.bind(File(path).openRead()).first).toString();
    _hashes[path] = (size: stat.size, modified: stat.modified, hash: hash);
    return hash;
  } on Object catch (error) {
    log.w('hash ${p.basename(path)}', error);
    return null;
  }
}

/// What a Windows loader failure means, in words, for an engine that exited
/// with [code] before it could say anything; null for any other exit.
String? engineExitReason(int? code) {
  if (code == null) return null;
  // Windows reports an NTSTATUS as a negative 32-bit exit code.
  final status = code & 0xFFFFFFFF;
  return switch (status) {
    0xC0000135 =>
      'Windows could not find a library it needs (exit 0xC0000135).',
    0xC000007B => 'Windows refused to load one of its files (exit 0xC000007B).',
    0xC000001D =>
      'This processor lacks an instruction the engine needs '
          '(exit 0xC000001D).',
    0xC0000005 => 'The engine crashed as it started (exit 0xC0000005).',
    _ => null,
  };
}
