import 'dart:async';

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

  /// True after [dispose]. Async completions use this to skip work, not
  /// just to swallow [notifyListeners].
  bool get isDisposed => _disposed;

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

  /// [notifyListeners], but never during a build.
  ///
  /// The mirror of the late-notify problem above. A service method that sets
  /// a "starting…" phase and notifies *before* its first `await` runs entirely
  /// synchronously in its caller — and the usual caller is a widget's
  /// `initState`, which runs inside the build phase. Every listener then calls
  /// `setState` during build, and Flutter replaces the offending subtree with
  /// a red error box.
  ///
  /// That is not hypothetical: it is what made both offline-evaluation
  /// download dialogs unopenable. Use this for any notify that can be reached
  /// synchronously from a widget's construction; plain [notifyListeners] is
  /// right everywhere else, and cheaper.
  ///
  /// A microtask, not `addPostFrameCallback`: a service must not need a
  /// Flutter binding in order to say something changed. The first version
  /// asked [SchedulerBinding] which phase it was in, and every plain `test()`
  /// that drives one of these controllers — no binding, no frames — died on
  /// "Binding has not yet been initialized". A microtask needs nothing, and
  /// it is sufficient: `buildScope` is synchronous, so the queue cannot drain
  /// until the build that scheduled this has fully unwound.
  void notifyListenersOutsideBuild() {
    if (_disposed) return;
    scheduleMicrotask(() {
      if (!_disposed) super.notifyListeners();
    });
  }
}
