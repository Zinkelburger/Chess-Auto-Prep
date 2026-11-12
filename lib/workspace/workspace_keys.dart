import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/app_keys.dart';
import '../ui/pane_tabs.dart';
import '../ui/screen_keys.dart';
import 'document/document_session.dart';

/// The keys of the workspace, wherever the focus is under [child]: the line
/// (← → Home End PgUp PgDn), the games of the file (↑ ↓), the board (F),
/// the last edit (Ctrl+Z), the card's tabs (Ctrl+Tab, Ctrl+Shift+Tab,
/// Ctrl+W) and the variations (Enter into the one at the cursor, Esc back
/// out), plus whatever the shell adds in [extra] and [leave] for the
/// window itself.
///
/// It encloses every column that works on the document, not the board
/// alone: a click on a row's `⋯` menu leaves the focus on that button, and
/// a binding that lived inside the board's column would then never see
/// Ctrl+Z — the one way back from an edit made in another column.
class WorkspaceKeys extends StatefulWidget {
  const WorkspaceKeys({
    super.key,
    required this.session,
    required this.editing,
    required this.tabs,
    this.extra = const {},
    this.leave = _nothingToLeave,
    this.save,
    this.escapeEndsEditing = true,
    required this.child,
  });

  final DocumentSession session;
  final ValueNotifier<bool> editing;
  final PaneTabs<Object> tabs;

  /// The window's own keys, which the shell binds: the settings, opening a
  /// file, the clipboard.
  final Map<ShortcutActivator, VoidCallback> extra;

  /// What Esc leaves once the workspace has nothing left to leave: the
  /// mode's sitting, full screen. Whether it left anything.
  final bool Function() leave;

  /// What Ctrl+S does with held edits, when not simply writing them to
  /// their file: a file this app may not write asks where they go.
  final VoidCallback? save;

  /// Whether Esc closes the edit strip. Not where `Read | Edit` shows the
  /// side the card is on: Esc leaving a variation must not also stop the
  /// edits being saved.
  final bool escapeEndsEditing;

  final Widget child;

  static bool _nothingToLeave() => false;

  @override
  State<WorkspaceKeys> createState() => _WorkspaceKeysState();
}

class _WorkspaceKeysState extends State<WorkspaceKeys> {
  /// A scope of the keys' own. A field under it that lets go of the focus
  /// — Enter in the game box, a click outside the note — hands it to its
  /// scope; were that the route's, which is above the keys, no key would
  /// reach them until something under them took the focus again. Tab still
  /// walks on out of the columns.
  final _scope = FocusScopeNode(
    debugLabel: 'workspace keys',
    traversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
  );

  DocumentSession get _session => widget.session;

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  void _undo() => unawaited(_session.undo());

  /// Esc leaves the innermost thing the user is in: a comment's line on
  /// the board, the variation, then the edit strip, then whatever the
  /// window adds.
  bool _escape() {
    if (_session.cursor.commentLine.value != null) {
      _session.cursor.closeCommentLine();
      return true;
    }
    if (_session.cursor.leaveVariation()) return true;
    if (widget.escapeEndsEditing && widget.editing.value) {
      widget.editing.value = false;
      return true;
    }
    return widget.leave();
  }

  Map<ShortcutActivator, VoidCallback> get _bindings {
    final tabs = widget.tabs;
    return {
      ...AppKey.back.bind(_session.cursor.back),
      ...AppKey.forward.bind(_session.cursor.forward),
      ...AppKey.start.bind(_session.cursor.toStart),
      ...AppKey.end.bind(_session.cursor.toEnd),
      ...AppKey.previousGame.bind(_session.previousGame),
      ...AppKey.nextGame.bind(_session.nextGame),
      ...AppKey.flip.bind(_session.flip),
      ...AppKey.undo.bind(_undo),
      ...AppKey.nextTab.bind(tabs.next),
      ...AppKey.previousTab.bind(tabs.previous),
      ...AppKey.closeTab.bind(tabs.closeCurrent),
      ...widget.extra,
    };
  }

  /// A key the workspace answers to, unless the user is typing: in a text
  /// field the arrows move the caret and Ctrl+Z takes back a word, and those
  /// keys are the field's. Ignoring the event leaves it to the field, which
  /// is why this is not [CallbackShortcuts]: that reports every bound key as
  /// handled and the field would never see it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    // Save belongs to the document even while an editor owns the caret.
    if (AppKey.save.accepts(event)) {
      (widget.save ?? _session.keepHeld)();
      return KeyEventResult.handled;
    }
    if (typingInText()) return KeyEventResult.ignored;
    // Enter is the variation's only while the workspace itself has the
    // focus: a focused button, menu entry or lesson has its own use for it.
    if (AppKey.enterVariation.accepts(event)) {
      final ours = FocusManager.instance.primaryFocus == node;
      return ours && _session.cursor.enterVariation()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    // Esc only now and then has something to leave; when it has nothing,
    // the key goes on to whoever else wants it. A held Esc leaves one
    // thing, not the whole ladder.
    if (AppKey.leave.accepts(event)) {
      return _escape() ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    for (final MapEntry(key: activator, value: run) in _bindings.entries) {
      if (activator.accepts(event, keys)) {
        run();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => FocusScope(
    node: _scope,
    autofocus: true,
    onKeyEvent: _onKey,
    child: widget.child,
  );
}
