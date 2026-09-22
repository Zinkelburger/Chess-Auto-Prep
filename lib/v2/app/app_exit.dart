import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

import '../diagnostics/log.dart';
import 'exit_guard.dart';

/// The way out of the app: what the user typed reaches the disk — or they
/// say to close without it — then the engines are quit, the polite path
/// where a killed app relies on the pipes instead, and the log is closed
/// last so their final words are in it.
///
/// The window can be asked to close again while the first answer is still
/// being worked out: a second click on the close button, or one made while
/// the question about the unsaved words is up. Every request gets that one
/// answer, so the engines are never stopped under a dialog and the log is
/// never closed twice. A request that ended with the window staying open is
/// forgotten, so the next click asks again.
final class AppExit {
  AppExit({
    required ExitGuard guard,
    required Future<void> Function() stopEngines,
    required Future<void> Function() closeLog,
  }) : _guard = guard,
       _stopEngines = stopEngines,
       _closeLog = closeLog;

  final ExitGuard _guard;
  final Future<void> Function() _stopEngines;
  final Future<void> Function() _closeLog;

  /// The answer being worked out for a close that was asked for already.
  Future<AppExitResponse>? _leaving;

  /// Whether the window may close, with the engines and the log shut when
  /// it may.
  Future<AppExitResponse> leave() => _leaving ??= _leaveOnce();

  Future<AppExitResponse> _leaveOnce() async {
    if (!await _draftIsSettled()) {
      _leaving = null;
      return AppExitResponse.cancel;
    }
    await _stopEngines();
    log.i('exit');
    await _closeLog();
    return AppExitResponse.exit;
  }

  /// Words in a field the user never left are committed the way clicking
  /// elsewhere commits them, by taking the focus away; the focus change is
  /// applied in a microtask, so the edit is only made a turn later. Then the
  /// file is waited for, because the window closes next — but not for ever,
  /// which is [ExitGuard]'s job.
  Future<bool> _draftIsSettled() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);
    return _guard.mayClose();
  }
}
