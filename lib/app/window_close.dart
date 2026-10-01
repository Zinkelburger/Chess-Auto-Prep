import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:window_manager/window_manager.dart';

import '../diagnostics/log.dart';

/// The window's close button, sent through the same door as every other
/// way out: [leave], which asks about unsaved words, saves what is waiting
/// and stops the engines before it answers.
///
/// The window plugin takes the close button over when it registers: on
/// Linux it disconnects Flutter's own handler, so without this a click
/// destroys the window and Flutter's exit request never comes — no
/// question, no last save, no `exit` line in the log. Holding the window
/// open and answering the plugin's close event puts the click back in
/// [leave]'s hands; the window goes only when [leave] says it may.
final class WindowClose with WindowListener {
  WindowClose(this._leave);

  final Future<AppExitResponse> Function() _leave;
  WindowManager get _window => windowManager;

  /// Whether the window is held open for [leave], so it has to be let go.
  bool _held = false;

  /// Taken down: an attach still under way holds nothing.
  bool _detached = false;

  /// Holds the window open on a close click. A window that cannot be held
  /// still closes the plugin's way; the log says why the question was not
  /// asked.
  Future<void> attach() async {
    try {
      await _window.ensureInitialized();
      if (_detached) return;
      _window.addListener(this);
      _held = true;
      // A detach from here on sends its release after this hold.
      await _window.setPreventClose(true);
    } on Object catch (error) {
      _window.removeListener(this);
      _held = false;
      log.w('hold the window open on close', error);
    }
  }

  @override
  void onWindowClose() => unawaited(close());

  /// Closes the window as its close button does; false when [leave] kept
  /// it open.
  Future<bool> close() async {
    if (await _leave() != AppExitResponse.exit) return false;
    // [leave] closed the log file; the console still hears an error.
    try {
      await _window.setPreventClose(false);
      await _window.destroy();
    } on Object catch (error) {
      log.e('close the window', error);
    }
    return true;
  }

  /// Lets the window go: the close button closes it the plugin's way
  /// again, and no click reaches [leave] once its owner is gone.
  void detach() {
    _detached = true;
    if (!_held) return;
    _held = false;
    _window.removeListener(this);
    unawaited(_release());
  }

  Future<void> _release() async {
    try {
      await _window.setPreventClose(false);
    } on Object catch (error) {
      log.w('let the window close', error);
    }
  }
}
