/// App-wide fallback for the Escape contract: "leave what I'm in".
///
/// Flutter dismisses a route on Escape only when that route is
/// `barrierDismissible`. That covers ordinary dialogs and nothing else — a
/// pushed page route (global Settings, Select Player) and a dialog opened with
/// `barrierDismissible: false` both leave Escape dead, which is exactly the
/// set of screens with no obvious keyboard way out.
///
/// Mounted above the [Navigator], this pops the top route when nothing closer
/// to the focus claimed the key.
///
/// **Not an `Actions` entry for [DismissIntent]**, which is the obvious way to
/// write this and does not work. `ShortcutManager.handleKeypress` resolves the
/// intent with `Actions.maybeFind`, which skips actions whose `isActionEnabled`
/// is false — but `Scaffold`'s `_DismissDrawerAction` leaves that getter at its
/// default `true` and overrides the intent-taking `isEnabled` instead. So on
/// every Scaffold-based screen the lookup stops at the drawer action, finds it
/// disabled for the intent, and gives up without ever walking further up. A
/// handler on the focus chain has no such competition.
///
/// Priority still works out the same way, and is the point: `Focus.onKeyEvent`
/// handlers run from the focused widget upward, so a screen that gives Escape
/// its own meaning — leave the line being drilled, blur the search box — is
/// deeper in the chain and still wins. This only runs when nobody closer
/// claimed the key, and it reports [KeyEventResult.ignored] when there is
/// nothing to pop, so Escape at the root is left for anything else that wants
/// it. Popping goes through [NavigatorState.maybePop], so a `PopScope`
/// guarding an in-flight job (the download progress dialogs) still blocks it.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class EscapeToPopScope extends StatelessWidget {
  const EscapeToPopScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      // Never a focus stop of its own — it exists only to sit on the chain
      // between the focused widget and the app.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKeyEvent,
      child: child,
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    // Looked up from the *focused* context, not from this node: this sits
    // above the Navigator, so searching upward from here finds nothing.
    // Starting at the focus also picks the innermost navigator when a screen
    // nests one.
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return KeyEventResult.ignored;
    final navigator = Navigator.maybeOf(focused);
    if (navigator == null || !navigator.canPop()) {
      return KeyEventResult.ignored;
    }
    unawaited(navigator.maybePop());
    return KeyEventResult.handled;
  }
}
