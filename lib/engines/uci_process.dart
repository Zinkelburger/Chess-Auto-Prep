import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../diagnostics/log.dart';

/// The lines in and out of an engine. UCI itself lives in `UciEngine`;
/// this is only the pipe, so a test can script the far end.
abstract interface class UciProcess {
  int get pid;

  /// Standard output one line at a time, done when the process has exited.
  /// Listen once.
  Stream<String> get lines;

  void send(String line);

  /// Ends the process now, without a UCI `quit`; waits a bounded time for
  /// the OS to confirm.
  Future<void> kill();
}

/// A child process joined by pipes.
///
/// The pipes tie its life to ours: when this process dies, even by
/// SIGKILL, the kernel closes them, the engine reads end of input and
/// quits. That is the exit-with-the-app guarantee `stockfish_exit_test.dart`
/// checks. Nothing here kills by name.
final class SpawnedProcess implements UciProcess {
  SpawnedProcess._(this._process, this.transcript) {
    // A write after the engine has gone is swallowed here rather than
    // surfacing as an unhandled error from the sink; `lines` ending is how
    // the engine's exit is noticed.
    _process.stdin.done.ignore();
    // Not UTF-8 on every platform: a Windows engine writes its paths in the
    // console's code page, and a decoding error here would go unheard.
    _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_remember, onError: (Object _) {});
  }

  /// Starts [executable] with [arguments], in [workingDirectory] when given,
  /// with [environment] added to this process's own.
  static Future<SpawnedProcess> start(
    String executable, {
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
    EngineTranscript? transcript,
  }) async => SpawnedProcess._(
    await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    ),
    transcript ?? EngineTranscript(),
  );

  final Process _process;
  final _errors = <String>[];

  /// The first lines the process wrote on either stream.
  final EngineTranscript transcript;

  /// The last few lines of standard error, for a failure message.
  List<String> get recentErrors => List.unmodifiable(_errors);

  @override
  int get pid => _process.pid;

  /// How the process ended, once it has.
  Future<int> get exitCode => _process.exitCode;

  /// Bytes that are not UTF-8 read as replacement characters rather than
  /// an error nobody listens for.
  @override
  Stream<String> get lines async* {
    yield* _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .map((line) {
          transcript.add(line);
          return line;
        });
    // A program may close stdout and keep running. The protocol owners use
    // stream completion as exit, so do not release ownership at pipe EOF.
    await _process.exitCode;
  }

  @override
  void send(String line) => _process.stdin.writeln(line);

  /// A process stuck in the kernel (an engine on a hung network mount, a
  /// GPU driver that will not return) outlives SIGKILL, so the wait for its
  /// exit has a limit.
  @override
  Future<void> kill() async {
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        log.w('engine', '$pid did not exit after kill');
        return -1;
      },
    );
  }

  void _remember(String line) {
    transcript.add(line);
    if (_errors.length == _keptErrors) _errors.removeAt(0);
    _errors.add(line);
  }
}

const _keptErrors = 20;
const _transcriptLines = 40;

/// The first 40 lines an engine wrote, standard output and standard
/// error in the order they arrived. A registration that fails shows them,
/// so the user reads the engine's own words (a usage banner, `Illegal
/// instruction`, a missing library) beside the app's one sentence.
final class EngineTranscript {
  final _lines = <String>[];

  List<String> get lines => List.unmodifiable(_lines);

  void add(String line) {
    if (_lines.length < _transcriptLines) _lines.add(line);
  }
}
