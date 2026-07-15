import 'package:flutter/foundation.dart';

/// Swallows [notifyListeners] calls that arrive after [dispose].
///
/// Notifier services often kick off async work (file loads, network
/// fetches) whose completions call [notifyListeners]; when the owning
/// provider is torn down first — common in widget tests — the plain
/// [ChangeNotifier] trips its used-after-dispose assertion. Mix this in
/// to drop those late notifications instead.
mixin SafeChangeNotifier on ChangeNotifier {
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }
}
