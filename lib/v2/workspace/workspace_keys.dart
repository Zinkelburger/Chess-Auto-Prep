import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/pane_tabs.dart';
import 'document_session.dart';
import 'engine_analysis.dart';

/// The keys of the workspace, wherever the focus is under [child]: the line
/// (← → Home End PgUp PgDn), the games of the file (↑ ↓), the board (F), the
/// engine (E), the edit strip (Ctrl+E), the last edit (Ctrl+Z) and the
/// card's tabs (Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+W), plus whatever the shell
/// adds in [extra] for the window itself.
///
/// It encloses every column that works on the document, not the board
/// alone: a click on a row's `⋯` menu leaves the focus on that button, and
/// a binding that lived inside the board's column would then never see
/// Ctrl+Z — the one way back from an edit made in another column.
class WorkspaceKeys extends StatelessWidget {
  const WorkspaceKeys({
    super.key,
    required this.session,
    required this.analysis,
    required this.editing,
    required this.tabs,
    this.extra = const {},
    required this.child,
  });

  final DocumentSession session;
  final EngineAnalysis analysis;
  final ValueNotifier<bool> editing;
  final PaneTabs<Object> tabs;

  /// The window's own keys, which the shell binds: the list pane, the
  /// actions, opening a file.
  final Map<ShortcutActivator, VoidCallback> extra;

  final Widget child;

  void _undo() => unawaited(session.undo());

  void _engine() =>
      unawaited(analysis.enabled ? analysis.disable() : analysis.enable());

  void _edit() => editing.value = !editing.value;

  Map<ShortcutActivator, VoidCallback> get _bindings => {
    const SingleActivator(LogicalKeyboardKey.arrowLeft): session.back,
    const SingleActivator(LogicalKeyboardKey.arrowRight): session.forward,
    const SingleActivator(LogicalKeyboardKey.home): session.toStart,
    const SingleActivator(LogicalKeyboardKey.end): session.toEnd,
    const SingleActivator(LogicalKeyboardKey.pageUp): session.toStart,
    const SingleActivator(LogicalKeyboardKey.pageDown): session.toEnd,
    const SingleActivator(LogicalKeyboardKey.arrowUp): session.previousGame,
    const SingleActivator(LogicalKeyboardKey.arrowDown): session.nextGame,
    const SingleActivator(LogicalKeyboardKey.keyF): session.flip,
    const SingleActivator(LogicalKeyboardKey.keyE): _engine,
    const SingleActivator(LogicalKeyboardKey.keyE, control: true): _edit,
    const SingleActivator(LogicalKeyboardKey.keyE, meta: true): _edit,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
    const SingleActivator(LogicalKeyboardKey.tab, control: true): tabs.next,
    const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true):
        tabs.previous,
    const SingleActivator(LogicalKeyboardKey.keyW, control: true):
        tabs.closeCurrent,
    const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
        tabs.closeCurrent,
    ...extra,
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
