import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Whether a text field has the caret: its keys are its own then, Alt+←
/// moving by a word rather than back through the history.
bool typingInText() {
  final focused = FocusManager.instance.primaryFocus?.context;
  return focused != null &&
      focused.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// [bindings] over a screen of its own, as [CallbackShortcuts] binds them,
/// except while a text field on it has the caret: the key is the field's.
class ScreenKeys extends StatelessWidget {
  const ScreenKeys({super.key, required this.bindings, required this.child});

  final Map<ShortcutActivator, VoidCallback> bindings;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (node, event) {
      if (typingInText()) return KeyEventResult.ignored;
      for (final MapEntry(key: activator, value: callback)
          in bindings.entries) {
        if (activator.accepts(event, HardwareKeyboard.instance)) {
          callback();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    },
    child: child,
  );
}
