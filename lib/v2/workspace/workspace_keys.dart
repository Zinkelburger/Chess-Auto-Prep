import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'document_session.dart';

/// The keys that walk the line and take the last edit back, wherever the
/// focus is under [child].
///
/// It encloses every column that works on the document, not the board alone:
/// a click on a row's `⋯` menu leaves the focus on that button, and a
/// binding that lived inside the board's column would then never see Ctrl+Z
/// — the one way back from an edit made in another column.
class WorkspaceKeys extends StatelessWidget {
  const WorkspaceKeys({super.key, required this.session, required this.child});

  final DocumentSession session;
  final Widget child;

  void _undo() => unawaited(session.undo());

  Map<ShortcutActivator, VoidCallback> get _bindings => {
    const SingleActivator(LogicalKeyboardKey.arrowLeft): session.back,
    const SingleActivator(LogicalKeyboardKey.arrowRight): session.forward,
    const SingleActivator(LogicalKeyboardKey.arrowUp): session.toStart,
    const SingleActivator(LogicalKeyboardKey.arrowDown): session.toEnd,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
  };

  /// A key the workspace answers to, unless the user is typing: in a text
  /// field the arrows move the caret and Ctrl+Z takes back a word, and those
  /// keys are the field's. Ignoring the event leaves it to the field, which
  /// is why this is not [CallbackShortcuts]: that reports every bound key as
  /// handled and the field would never see it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_typing) return KeyEventResult.ignored;
    for (final MapEntry(key: activator, value: run) in _bindings.entries) {
      if (activator.accepts(event, HardwareKeyboard.instance)) {
        run();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  bool get _typing {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused != null &&
        focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(autofocus: true, onKeyEvent: _onKey, child: child);
}
