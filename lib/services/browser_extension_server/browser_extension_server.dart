/// Browser Extension Server Service
/// Provides HTTP endpoints for the Lichess browser extension to add lines to repertoires
/// 
/// Endpoints:
/// - GET /list-repertoires - List all repertoire files with metadata
/// - POST /add-line - Add a line to a specific repertoire
/// - GET /health - Health check
library;

/// Abstract interface for the browser extension server
abstract class BrowserExtensionServer {
  /// Start the server on the specified port
  Future<bool> start({int port = 9812});
  
  /// Stop the server
  Future<void> stop();
  
  /// Whether the server is currently running
  bool get isRunning;
  
  /// The port the server is listening on (null if not running)
  int? get port;
  
  /// Whether this platform supports the server
  bool get isSupported;
}




