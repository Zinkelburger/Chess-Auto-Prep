import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/utils/log.dart';

import 'engine_connection.dart';
import 'engine_interrupt.dart';
import 'stockfish_bundle.dart';
import 'uci_handshake.dart';

/// A Stockfish binary driven over stdin/stdout pipes (desktop platforms).
class ProcessConnection implements EngineConnection {
  Process? _process;
  final StreamController<String> _stdoutController =
      StreamController<String>.broadcast();
  StreamSubscription<String>? _processSubscription;
  bool _isDisposed = false;
  final Completer<void> _done = Completer<void>();

  /// Grace period between SIGTERM and SIGKILL on POSIX.
  static const _killGracePeriod = Duration(seconds: 2);

  ProcessConnection._();

  static Future<ProcessConnection> create() async {
    final connection = ProcessConnection._();
    try {
      await connection._init();
      return connection;
    } catch (_) {
      connection.dispose();
      rethrow;
    }
  }

  /// Resolve the Stockfish binary path, extracting from assets if needed.
  ///
  /// The result is cached after the first successful call so subsequent
  /// workers skip the platform channel and file-system checks entirely.
  ///
  /// Must be called from the main isolate (uses platform channels for
  /// asset loading and path resolution). Worker isolates should receive
  /// the resolved path string instead of calling this directly.
  static Future<String> resolveExecutablePath() =>
      StockfishBundle.ensureExecutable();

  Future<void> _init() async {
    try {
      final executablePath = await resolveExecutablePath();
      log.i('Starting Stockfish from: $executablePath');

      final process = _process = await Process.start(executablePath, []);

      _processSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (!_isDisposed) _stdoutController.add(line);
          }, onError: _reportError);

      // Drain stderr to prevent buffer fill-up that can stall the process.
      unawaited(process.stderr.drain<void>().catchError(_reportError));
      unawaited(process.stdin.done.then<void>((_) {}, onError: _reportError));

      unawaited(
        process.exitCode.then((code) {
          if (_isDisposed) return;
          if (!_done.isCompleted) _done.complete();
          _reportError(EngineProcessExitedError(code));
        }),
      );
    } catch (e) {
      log.e('Error starting Stockfish process: $e');
      rethrow;
    }
  }

  void _reportError(Object error) {
    if (!_isDisposed && !_stdoutController.isClosed) {
      _stdoutController.addError(error);
    }
  }

  @override
  Stream<String> get stdout => _stdoutController.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> waitForReady() => performUciHandshake(this);

  @override
  void sendCommand(String command) {
    final process = _process;
    if (process != null && !_isDisposed) {
      process.stdin.writeln(command);
    }
  }

  @override
  void dispose() {
    if (_isDisposed) return; // idempotent
    _isDisposed = true;
    if (!_done.isCompleted) _done.complete();
    unawaited(_processSubscription?.cancel());

    final process = _process;
    _process = null;
    if (process != null) _terminate(process);
    unawaited(_stdoutController.close());
  }

  /// Ask politely, then SIGTERM; on POSIX follow up with SIGKILL, because a
  /// busy engine may ignore SIGTERM. Windows' kill() already terminates hard
  /// (and sigkill would throw there).
  static void _terminate(Process process) {
    try {
      process.stdin.writeln('quit');
    } catch (_) {
      // stdin may already be closed.
    }
    process.kill();
    if (Platform.isWindows) return;
    unawaited(
      Future.delayed(_killGracePeriod, () {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {
          // The process may have already exited.
        }
      }),
    );
  }
}
