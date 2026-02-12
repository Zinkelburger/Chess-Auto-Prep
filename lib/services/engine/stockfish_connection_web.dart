import 'dart:async' show Completer, StreamController, TimeoutException;
import 'package:web/web.dart' as web;
import 'dart:js_interop';
import 'engine_connection.dart';

/// Web implementation - uses Stockfish.js via Web Worker
bool get isStockfishAvailable => true;

Future<EngineConnection?> createStockfishConnection() async {
  try {
    final connection = WebStockfishConnection();
    await connection._init();
    return connection;
  } catch (e) {
    print('Failed to create web Stockfish connection: $e');
    return null;
  }
}

/// Web Worker-based Stockfish connection
/// Uses stockfish.js (WebAssembly) running in a background thread
class WebStockfishConnection implements EngineConnection {
  web.Worker? _worker;
  final StreamController<String> _stdoutController = StreamController<String>.broadcast();
  bool _isReady = false;
  Completer<void>? _readyCompleter;
  Completer<void>? _uciOkCompleter;
  
  @override
  Stream<String> get stdout => _stdoutController.stream;
  
  Future<void> _init() async {
    try {
      // Create the Web Worker pointing DIRECTLY to stockfish.js
      // The stockfish.js file is designed to run as a Worker itself
      // (it sets up its own onmessage handler and uses postMessage for output)
      _worker = web.Worker('engines/stockfish.js'.toJS);
      
      // Listen for messages FROM the worker (Engine Output)
      _worker!.onmessage = _onMessage.toJS;
      
      _worker!.onerror = ((web.ErrorEvent event) {
        print('Stockfish Worker Error: ${event.message}');
        _stdoutController.addError(event.message);
      }).toJS;
      
      print('Stockfish Web Worker created successfully');
    } catch (e) {
      print('Error creating Stockfish Web Worker: $e');
      rethrow;
    }
  }
  
  void _onMessage(web.MessageEvent event) {
    // Convert JS value to Dart string using dartify
    final data = event.data;
    String rawMessage;
    try {
      rawMessage = (data as JSString).toDart;
    } catch (e) {
      print('[Web Stockfish] Failed to convert message: $e, raw: $data');
      return;
    }
    
    // Split by newline in case multiple commands came in one batch
    // This matches the behavior of the official Stockfish.js wrapper
    final lines = rawMessage.split('\n');
    
    for (var line in lines) {
      final message = line.trim();
      if (message.isEmpty) continue;
      
      print('[Web Stockfish] Received: $message');
      
      // Handle the message
      _stdoutController.add(message);
      
      // Check for ready signals
      if (message == 'uciok') {
        print('[Web Stockfish] UCI OK received');
        if (_uciOkCompleter != null && !_uciOkCompleter!.isCompleted) {
          _uciOkCompleter!.complete();
        }
      } else if (message == 'readyok') {
        _isReady = true;
        print('[Web Stockfish] READY OK - Engine is ready!');
        if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
          _readyCompleter!.complete();
        }
      } else if (message.startsWith('error:')) {
        print('[Web Stockfish] ERROR: $message');
      } else if (message.startsWith('bestmove')) {
        print('[Web Stockfish] Best move: $message');
      }
    }
  }
  
  @override
  Future<void> waitForReady() async {
    print('[Web Stockfish] waitForReady called, _isReady=$_isReady');
    if (_isReady) return;

    // Step 1: Initialize UCI protocol
    // stockfish.js queues commands until WASM is compiled, then processes them
    // So we can send 'uci' immediately and it will be handled when ready
    _uciOkCompleter = Completer<void>();
    
    print('[Web Stockfish] Sending "uci" command...');
    sendCommand('uci');
    
    try {
      await _uciOkCompleter!.future.timeout(const Duration(seconds: 30));
      print('[Web Stockfish] UCI initialized (received uciok)');
    } catch (e) {
      print('[Web Stockfish] Timeout waiting for uciok: $e');
      rethrow;
    }

    // Step 2: Check Readiness
    _readyCompleter = Completer<void>();
    
    print('[Web Stockfish] Sending "isready" command...');
    sendCommand('isready');
    
    // Wait for readyok with timeout
    print('[Web Stockfish] Waiting for readyok (timeout: 30s)...');
    try {
      await _readyCompleter!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          print('[Web Stockfish] ⚠️ Timeout waiting for readyok!');
          _isReady = false;
          throw TimeoutException('Stockfish did not respond with readyok');
        },
      );
      print('[Web Stockfish] ✓ Engine ready!');
    } catch (e) {
      print('[Web Stockfish] Error waiting for ready: $e');
      rethrow;
    }
  }
  
  @override
  void sendCommand(String command) {
    if (_worker == null) {
      print('⚠️ Stockfish Worker not initialized');
      return;
    }
    _worker!.postMessage(command.toJS);
  }
  
  @override
  void dispose() {
    _worker?.terminate();
    _stdoutController.close();
  }
}
