import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The lines in and out of an engine. UCI itself lives in `UciEngine`;
/// this is only the pipe, so a test can script the far end.
abstract interface class UciProcess {
  int get pid;

  /// Standard output one line at a time, done when the process has exited.
  /// Listen once.
  Stream<String> get lines;

  void send(String line);

  /// Ends the process now, without a UCI `quit`.
  Future<void> kill();
}

/// A child process joined by pipes.
///
/// The pipes tie its life to ours: when this process dies, even by
/// SIGKILL, the kernel closes them, the engine reads end of input and
/// quits. That is the exit-with-the-app guarantee `stockfish_exit_test.dart`
/// checks. Nothing here kills by name.
final class SpawnedProcess implements UciProcess {
  SpawnedProcess._(this._process) {
    // A write after the engine has gone is swallowed here rather than
    // surfacing as an unhandled error from the sink; `lines` ending is how
    // the engine's exit is noticed.
    _process.stdin.done.ignore();
    _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_remember);
  }

  /// Starts [executable] with [arguments], in [workingDirectory] when given,
  /// with [environment] added to this process's own.
  static Future<SpawnedProcess> start(
    String executable, {
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
  }) async => SpawnedProcess._(
    await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    ),
  );

  final Process _process;
  final _errors = <String>[];

  /// The last few lines of standard error, for a failure message.
  List<String> get recentErrors => List.unmodifiable(_errors);

  @override
  int get pid => _process.pid;

  @override
  Stream<String> get lines =>
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  void send(String line) => _process.stdin.writeln(line);

  @override
  Future<void> kill() async {
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode;
  }

  void _remember(String line) {
    if (_errors.length == _keptErrors) _errors.removeAt(0);
    _errors.add(line);
  }
}

const _keptErrors = 20;
