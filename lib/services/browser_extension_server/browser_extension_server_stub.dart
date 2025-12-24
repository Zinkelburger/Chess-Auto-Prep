/// Stub implementation of the Browser Extension Server
/// Used on platforms that don't support the server (mobile, web)
library;

import 'browser_extension_server.dart';

/// Factory function for conditional import
BrowserExtensionServer createBrowserExtensionServer() => BrowserExtensionServerStub();

/// Stub implementation that does nothing
class BrowserExtensionServerStub implements BrowserExtensionServer {
  @override
  bool get isRunning => false;
  
  @override
  int? get port => null;
  
  @override
  bool get isSupported => false;
  
  @override
  Future<bool> start({int port = 9812}) async {
    // Not supported on this platform
    return false;
  }
  
  @override
  Future<void> stop() async {
    // No-op
  }
}


