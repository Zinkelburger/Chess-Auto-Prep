import '../diagnostics/log.dart';

/// Whether the window fills the screen: F11 and the Actions menu turn it,
/// Esc leaves it.
///
/// The desktop is asked through the environment's `setFullScreen`, one
/// request after the other, so two quick presses end where the second
/// said. [on] is what was last asked; a request the desktop refused puts it
/// back to what the window last did and is said to the user. A window the
/// desktop put in full screen some other way is left to the desktop.
final class FullScreen {
  FullScreen(this._set, {required void Function(String sentence) say})
    : _say = say;

  final Future<void> Function(bool on) _set;
  final void Function(String sentence) _say;
  bool _on = false;

  /// What the window last did.
  bool _done = false;
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
    _asked = _asked.then((_) => _apply(on));
  }

  Future<void> _apply(bool on) async {
    try {
      await _set(on);
      _done = on;
    } on Object catch (error) {
      final doing = on ? 'fill the screen' : 'leave full screen';
      log.w(doing, error);
      // A later request, already asked, still says what is wanted.
      if (_on == on) _on = _done;
      _say('Could not $doing: $error');
    }
  }
}
