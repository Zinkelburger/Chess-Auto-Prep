import 'package:flutter/services.dart';

import '../diagnostics/log.dart';

/// The desktop runner's queued file-open protocol. Register before announcing
/// readiness so startup arguments and later OS handoffs use the same route.
final class NativeFileRequests {
  NativeFileRequests({required this.open, MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('chess_auto_prep/file_open');

  final Future<void> Function(String path) open;
  final MethodChannel _channel;
  bool _disposed = false;

  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'open') throw MissingPluginException(call.method);
      await _receive(call.arguments);
    });
    try {
      await _receive(await _channel.invokeMethod<Object?>('ready'));
    } on MissingPluginException {
      // Unsupported platforms have no native file-open channel.
    } on Object catch (error) {
      log.w('receive desktop files', error);
    }
  }

  Future<void> _receive(Object? paths) async {
    if (_disposed || paths is! List) return;
    final first = paths
        .whereType<String>()
        .where((p) => p.trim().isNotEmpty)
        .firstOrNull;
    if (first != null) await open(first);
  }

  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
  }
}
