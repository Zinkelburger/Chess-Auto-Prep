/// Files the desktop asked the app to open — a double-clicked `.pgn`, an
/// "Open with" pick, a file dropped on the executable.
///
/// The native runners gather these and hand them over on one method channel:
/// the paths on the first instance's command line, and the paths later
/// instances forward before exiting (the OS starts a fresh process per
/// double-click; the runner finds the running one, passes it the files, and
/// quits, so there is only ever one window). Paths queue natively until Dart
/// calls `ready`, so a file opened while the app is still starting is not
/// lost — the runner has already checked each one exists.
///
/// A channel rather than the tournament screen's request file because these
/// are the running process's own arguments, not something an outside agent
/// leaves behind for a later launch.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FileOpenRequests {
  FileOpenRequests({required this.onOpen, MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'chess_auto_prep/file_open';

  /// Called with the absolute paths to open, never empty.
  final void Function(List<String> paths) onOpen;

  final MethodChannel _channel;
  bool _stopped = false;

  /// Listen for files, then drain whatever the runner queued before now.
  ///
  /// Never throws: on a platform with no runner support (tests, mobile) the
  /// `ready` call has no handler and the service simply hears nothing.
  Future<void> start() async {
    _channel.setMethodCallHandler(_onMethodCall);
    try {
      _deliver(await _channel.invokeListMethod<String>('ready'));
    } on MissingPluginException {
      // No native side for this channel — nothing will ever arrive.
    } catch (error) {
      debugPrint('FileOpenRequests: ready failed: $error');
    }
  }

  void stop() {
    _stopped = true;
    _channel.setMethodCallHandler(null);
  }

  Future<Object?> _onMethodCall(MethodCall call) async {
    if (call.method != 'open') {
      throw MissingPluginException('Unknown method ${call.method}');
    }
    final arguments = call.arguments;
    _deliver(arguments is List ? arguments.whereType<String>().toList() : null);
    return null;
  }

  void _deliver(List<String>? paths) {
    if (_stopped || paths == null) return;
    final usable = [
      for (final path in paths)
        if (path.trim().isNotEmpty) path,
    ];
    if (usable.isEmpty) return;
    onOpen(usable);
  }
}
