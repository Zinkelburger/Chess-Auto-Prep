/// Factory for creating platform-appropriate BrowserExtensionServer
/// Uses conditional imports to select the right implementation
library;

import 'browser_extension_server.dart';
import 'browser_extension_server_io.dart'
    if (dart.library.html) 'browser_extension_server_stub.dart'
    if (dart.library.js_interop) 'browser_extension_server_stub.dart';

export 'browser_extension_server.dart';

class BrowserExtensionServerFactory {
  static BrowserExtensionServer? _instance;
  
  /// Get the singleton instance of the browser extension server
  static BrowserExtensionServer get instance {
    _instance ??= createBrowserExtensionServer();
    return _instance!;
  }
  
  /// Check if the server is supported on this platform
  static bool get isSupported => instance.isSupported;
  
  /// Start the server (convenience method)
  static Future<bool> start({int port = 9812}) => instance.start(port: port);
  
  /// Stop the server (convenience method)
  static Future<void> stop() => instance.stop();
}



