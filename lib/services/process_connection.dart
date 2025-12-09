import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'engine_connection.dart';

class ProcessConnection implements EngineConnection {
  Process? _process;
  final StreamController<String> _stdoutController = StreamController<String>();
  StreamSubscription? _processSubscription;
  bool _isDisposed = false;

  ProcessConnection._();

  static Future<ProcessConnection> create() async {
    final connection = ProcessConnection._();
    await connection._init();
    return connection;
  }

  Future<void> _init() async {
    String? executablePath;
    
    try {
      // Determine platform-specific binary name
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

      // Get application support directory
      final dir = await getApplicationSupportDirectory();
      final file = File(path.join(dir.path, binaryName));

      // Check if binary exists, if not copy from assets
      if (!await file.exists()) {
        print('Extracting Stockfish binary to ${file.path}...');
        // Ensure directory exists
        await file.parent.create(recursive: true);
        
        final byteData = await rootBundle.load('assets/executables/$binaryName');
        await file.writeAsBytes(byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ));
        
        // Make executable on Linux/Mac
        if (!Platform.isWindows) {
          await Process.run('chmod', ['+x', file.path]);
        }
      }
      
      executablePath = file.path;
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
    // Perform UCI handshake: uci -> uciok -> isready -> readyok
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

    // Tune threads/hash for desktop
    final threads = Platform.numberOfProcessors.clamp(2, 8);
    sendCommand('setoption name Threads value $threads');
    sendCommand('setoption name Hash value 512');
  }

  @override
  void sendCommand(String command) {
    if (_process != null && !_isDisposed) {
      _process!.stdin.writeln(command);
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _processSubscription?.cancel();
    _process?.kill();
    _stdoutController.close();
  }
}
