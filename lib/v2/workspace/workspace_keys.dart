import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/pane_tabs.dart';
import 'document_session.dart';
import 'engine_analysis.dart';
import 'move_field.dart';

/// The keys of the workspace, wherever the focus is under [child]: the line
/// (← → Home End PgUp PgDn), the games of the file (↑ ↓), the board (F), the
/// engine (E), the edit strip (Ctrl+E), the last edit (Ctrl+Z), the card's
/// tabs (Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+W), the move field under the
/// board (/), and the variations (Enter into the one at the cursor, Esc
/// back out), plus whatever the shell adds in [extra] and [leave] for the
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
    required this.analysis,
    required this.editing,
    required this.tabs,
    required this.moves,
    this.extra = const {},
    this.leave = _nothingToLeave,
    required this.child,
  });

  final DocumentSession session;
  final EngineAnalysis analysis;
  final ValueNotifier<bool> editing;
  final PaneTabs<Object> tabs;

  /// The move field's focus, which `/` puts the keys in.
  final MoveEntry moves;

  /// The window's own keys, which the shell binds: the list pane, the
  /// actions, opening a file.
  final Map<ShortcutActivator, VoidCallback> extra;

  /// What Esc leaves once the workspace has nothing left to leave: the
  /// mode's sitting, full screen. Whether it left anything.
  final bool Function() leave;

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

  /// E turns the engine off at any time, and on only while the whole game
  /// is on view: it would read a hidden puzzle answer out.
  void _engine() {
    final analysis = widget.analysis;
    if (analysis.enabled) return unawaited(analysis.disable());
    if (_session.shownTo == null) unawaited(analysis.enable());
  }

  /// Ctrl+E closes the edit strip at any time, and opens it only while the
  /// whole game is on view: its note field would show what a hidden puzzle
  /// answer's note says.
  void _edit() {
    final editing = widget.editing;
    if (editing.value) {
      editing.value = false;
    } else if (_session.shownTo == null) {
      editing.value = true;
    }
  }

  /// Esc leaves the innermost thing the user is in: a comment's line on
  /// the board, the variation, then the edit strip, then whatever the
  /// window adds.
  bool _escape() {
    if (_session.commentLine.value != null) {
      _session.closeCommentLine();
      return true;
    }
    if (_session.leaveVariation()) return true;
    if (widget.editing.value) {
      widget.editing.value = false;
      return true;
    }
    return widget.leave();
  }

  /// Keys that only now and then have something to do. When they have
  /// nothing, the key goes on to whoever else wants it. A held Esc leaves
  /// one thing, not the whole ladder.
  Map<ShortcutActivator, bool Function()> get _whenThere => {
    const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false):
        _escape,
  };

  /// Enter is the variation's only while the workspace itself has the
  /// focus: a focused button, menu entry or lesson has its own use for it.
  static const _enter = [
    SingleActivator(LogicalKeyboardKey.enter),
    SingleActivator(LogicalKeyboardKey.numpadEnter),
  ];

  Map<ShortcutActivator, VoidCallback> get _bindings {
    final tabs = widget.tabs;
    return {
      const SingleActivator(LogicalKeyboardKey.arrowLeft): _session.back,
      const SingleActivator(LogicalKeyboardKey.arrowRight): _session.forward,
      const SingleActivator(LogicalKeyboardKey.home): _session.toStart,
      const SingleActivator(LogicalKeyboardKey.end): _session.toEnd,
      const SingleActivator(LogicalKeyboardKey.pageUp): _session.toStart,
      const SingleActivator(LogicalKeyboardKey.pageDown): _session.toEnd,
      const SingleActivator(LogicalKeyboardKey.arrowUp): _session.previousGame,
      const SingleActivator(LogicalKeyboardKey.arrowDown): _session.nextGame,
      const SingleActivator(LogicalKeyboardKey.keyF): _session.flip,
      const SingleActivator(LogicalKeyboardKey.keyE): _engine,
      const SingleActivator(LogicalKeyboardKey.keyE, control: true): _edit,
      const SingleActivator(LogicalKeyboardKey.keyE, meta: true): _edit,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
      const SingleActivator(LogicalKeyboardKey.keyS, control: true):
          _session.keepHeld,
      const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
          _session.keepHeld,
      const SingleActivator(LogicalKeyboardKey.tab, control: true): tabs.next,
      const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true):
          tabs.previous,
      const SingleActivator(LogicalKeyboardKey.keyW, control: true):
          tabs.closeCurrent,
      const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
          tabs.closeCurrent,
      // A character, not a key: `/` is Shift+7 on some keyboards.
      const CharacterActivator('/'): widget.moves.focus.requestFocus,
      ...widget.extra,
    };
  }

  /// A key the workspace answers to, unless the user is typing: in a text
  /// field the arrows move the caret and Ctrl+Z takes back a word, and those
  /// keys are the field's. Ignoring the event leaves it to the field, which
  /// is why this is not [CallbackShortcuts]: that reports every bound key as
  /// handled and the field would never see it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_typing) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (_enter.any((enter) => enter.accepts(event, keys))) {
      final ours = FocusManager.instance.primaryFocus == node;
      return ours && _session.enterVariation()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    for (final MapEntry(key: activator, value: run) in _whenThere.entries) {
      if (activator.accepts(event, keys)) {
        return run() ? KeyEventResult.handled : KeyEventResult.ignored;
      }
    }
    for (final MapEntry(key: activator, value: run) in _bindings.entries) {
      if (activator.accepts(event, keys)) {
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
  Widget build(BuildContext context) => FocusScope(
    node: _scope,
    autofocus: true,
    onKeyEvent: _onKey,
    child: widget.child,
  );
}
