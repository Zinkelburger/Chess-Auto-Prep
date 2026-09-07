import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/utils/log.dart';

import 'engine_connection.dart';
import 'uci_handshake.dart';
import 'stockfish_bundle.dart';

class ProcessConnection implements EngineConnection {
  Process? _process;
  final StreamController<String> _stdoutController =
      StreamController<String>.broadcast();
  StreamSubscription? _processSubscription;
  bool _isDisposed = false;
  final Completer<void> _done = Completer<void>();

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

      _process = await Process.start(executablePath, []);

      _processSubscription = _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (!_isDisposed) _stdoutController.add(line);
          }, onError: _reportError);

      // Drain stderr to prevent buffer fill-up that can stall the process.
      unawaited(_process!.stderr.drain<void>().catchError(_reportError));
      unawaited(_process!.stdin.done.then<void>((_) {}, onError: _reportError));

      unawaited(
        _process!.exitCode.then((code) {
          if (_isDisposed) return;
          if (!_done.isCompleted) _done.complete();
          if (!_stdoutController.isClosed) {
            _stdoutController.addError(
              StateError('Stockfish process exited ($code)'),
            );
          }
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
    if (_process != null && !_isDisposed) {
      _process!.stdin.writeln(command);
    }
  }

  @override
  void dispose() {
    if (_isDisposed) return; // idempotent
    _isDisposed = true;
    if (!_done.isCompleted) _done.complete();
    unawaited(_processSubscription?.cancel());

    final proc = _process;
    _process = null;
    if (proc != null) {
      try {
        proc.stdin.writeln('quit');
      } catch (_) {
        /* stdin may be closed */
      }
      proc.kill(); // SIGTERM on POSIX, TerminateProcess on Windows
      if (!Platform.isWindows) {
        // On POSIX, the initial kill() sends SIGTERM which the process may
        // ignore. Schedule a SIGKILL fallback. On Windows, kill() already
        // does a hard termination so this is unnecessary (and sigkill would
        // throw).
        Future.delayed(const Duration(seconds: 2), () {
          try {
            proc.kill(ProcessSignal.sigkill);
          } catch (_) {
            /* process may have already exited */
          }
        });
      }
    }
    unawaited(_stdoutController.close());
  }
}
