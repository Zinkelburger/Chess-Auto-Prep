import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'engine_connection.dart';

class ProcessConnection implements EngineConnection {
  Process? _process;
  final StreamController<String> _stdoutController = StreamController<String>.broadcast();
  StreamSubscription? _processSubscription;
  bool _isDisposed = false;

  /// Cached resolved path — avoids repeated file-existence checks and
  /// platform-channel calls for every worker spawn.
  static String? _cachedPath;

  ProcessConnection._();

  static Future<ProcessConnection> create() async {
    final connection = ProcessConnection._();
    await connection._init();
    return connection;
  }

  /// Resolve the Stockfish binary path, extracting from assets if needed.
  ///
  /// The result is cached after the first successful call so subsequent
  /// workers skip the platform channel and file-system checks entirely.
  ///
  /// Must be called from the main isolate (uses platform channels for
  /// asset loading and path resolution). Worker isolates should receive
  /// the resolved path string instead of calling this directly.
  static Future<String> resolveExecutablePath() async {
    if (_cachedPath != null) return _cachedPath!;

    String binaryName;
    if (Platform.isWindows) {
      binaryName = 'stockfish-windows.exe';
    } else if (Platform.isMacOS) {
      binaryName = 'stockfish-macos';
    } else if (Platform.isLinux) {
      binaryName = 'stockfish-linux';
    } else {
      throw UnsupportedError('Unsupported desktop platform');
    }

    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, binaryName));

    if (!await file.exists()) {
      print('Extracting Stockfish binary to ${file.path}...');
      await file.parent.create(recursive: true);

      final byteData =
          await rootBundle.load('assets/executables/$binaryName.gz');
      final compressed = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final decompressed = gzip.decode(compressed);
      await file.writeAsBytes(decompressed, flush: true);

      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', file.path]);
      }
    }

    _cachedPath = file.path;
    return _cachedPath!;
  }

  Future<void> _init() async {
    try {
      final executablePath = await resolveExecutablePath();
      print('Starting Stockfish from: $executablePath');
      
      _process = await Process.start(executablePath, []);
      
      _processSubscription = _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (!_isDisposed) {
          _stdoutController.add(line);
        }
      });

    } catch (e) {
      print('Error starting Stockfish process: $e');
      rethrow;
    }
  }

  @override
  Stream<String> get stdout => _stdoutController.stream;

  @override
  Future<void> waitForReady() async {
    // UCI handshake only — callers configure Hash / Threads themselves.
    // Previously this set Hash 512 + multi-thread, causing every process
    // (including pool workers that only need 16 MB) to briefly allocate
    // 512 MB of RAM that the OS may never reclaim.
    final uciOk = Completer<void>();
    final readyOk = Completer<void>();
    late StreamSubscription sub;

    sub = stdout.listen((line) {
      if (line.trim() == 'uciok' && !uciOk.isCompleted) {
        uciOk.complete();
      } else if (line.trim() == 'readyok' && !readyOk.isCompleted) {
        readyOk.complete();
      }
    });

    sendCommand('uci');
    await uciOk.future.timeout(const Duration(seconds: 10));

    sendCommand('isready');
    await readyOk.future.timeout(const Duration(seconds: 10));

    await sub.cancel();
  }

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
    _processSubscription?.cancel();

    final proc = _process;
    _process = null;
    if (proc != null) {
      // Ask Stockfish to exit gracefully, then SIGTERM.
      // Schedule a SIGKILL fallback in case it doesn't respond.
      try {
        proc.stdin.writeln('quit');
      } catch (_) {}
      proc.kill(); // SIGTERM
      Future.delayed(const Duration(seconds: 2), () {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {} // already exited — ignore
      });
    }
    _stdoutController.close();
  }
}
