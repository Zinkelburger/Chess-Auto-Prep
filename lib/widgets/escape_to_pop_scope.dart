/// App-wide fallback for the Escape contract: "leave what I'm in".
///
/// Flutter dismisses a route on Escape only when that route is
/// `barrierDismissible`. That covers ordinary dialogs and nothing else — a
/// pushed page route (global Settings, Select Player) and a dialog opened with
/// `barrierDismissible: false` both leave Escape dead, which is exactly the
/// set of screens with no obvious keyboard way out.
///
/// Mounted above the [Navigator], this catches the [DismissIntent] that the
/// modal route declined and pops the top route instead.
///
/// Priority is the point. `Focus.onKeyEvent` handlers run from the focused
/// widget upward *before* any `Shortcuts`/`Actions` lookup, so a screen that
/// gives Escape its own meaning — leave the line being drilled, back to the
/// first tab — still wins, and this only runs when nobody closer claimed the
/// key. Popping goes through [NavigatorState.maybePop], so a `PopScope`
/// guarding an in-flight job (the download progress dialogs) still blocks it.
library;

import 'package:flutter/widgets.dart';

class EscapeToPopScope extends StatelessWidget {
  const EscapeToPopScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{DismissIntent: _PopTopRouteAction()},
      child: child,
    );
  }
}

class _PopTopRouteAction extends ContextAction<DismissIntent> {
  /// Disabled at the root route, so Escape on the home screen is left for
  /// anything else that wants it rather than being silently swallowed.
  @override
  bool isEnabled(DismissIntent intent, [BuildContext? context]) {
    if (context == null) return false;
    return Navigator.maybeOf(context)?.canPop() ?? false;
  }

  @override
  Object? invoke(DismissIntent intent, [BuildContext? context]) {
    if (context != null) Navigator.maybeOf(context)?.maybePop();
    return null;
  }
}
