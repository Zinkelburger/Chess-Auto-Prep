import '../diagnostics/log.dart';

/// Whether the window fills the screen: F11 and the Actions menu turn it,
/// Esc leaves it.
///
/// The desktop is asked through the environment's `setFullScreen`, one
/// request after the other, so two quick presses end where the second
/// said. What this remembers is what it last asked for; a window the desktop
/// put in full screen some other way is left to the desktop.
final class FullScreen {
  FullScreen(this._set);

  final Future<void> Function(bool on) _set;
  bool _on = false;
  Future<void> _asked = Future.value();

  bool get on => _on;

  void toggle() => _ask(!_on);

  /// Out of full screen; whether the window was in it.
  bool leave() {
    if (!_on) return false;
    _ask(false);
    return true;
  }

  void _ask(bool on) {
    _on = on;
    _asked = _asked
        .then((_) => _set(on))
        .catchError(
          (Object error) =>
              log.w('${on ? 'enter' : 'leave'} full screen', error),
        );
  }
}
