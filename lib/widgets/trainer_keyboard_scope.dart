import 'dart:async';

import 'package:flutter/material.dart';

/// Shared keyboard/focus plumbing for the board trainers (Repertoire, Tactics).
///
/// Both trainers pair a chess board + a type-a-move text field + panel-level
/// keyboard shortcuts. Getting the focus contract subtly wrong breaks either
/// typing (an ancestor steals the keystrokes) or shortcuts (nothing is focused
/// to receive them). This widget centralises that contract so each trainer only
/// has to supply its own key meanings via [onKeyEvent].
///
/// Two focus modes, chosen with [holdsFocus]:
///
///  * `holdsFocus: false` (default) — the scope never takes primary focus, so a
///    descendant text field (e.g. the move input) can own focus for typing.
///    Key events from focused descendants still bubble up to [onKeyEvent]. Use
///    this when the trainer's always-available keys are ones the move input
///    ignores anyway (e.g. Space) and typing is the primary interaction.
///
///  * `holdsFocus: true` — the scope autofocuses and re-grabs focus on tap
///    (requires [focusNode]), so navigation shortcuts (arrows, letters) keep
///    working whenever the user isn't actively typing. Hand focus to the move
///    input explicitly (e.g. `moveInputKey.currentState?.focus()`) when the
///    trainer wants keystrokes to go there instead.
///
/// In `holdsFocus` mode the scope also *heals* orphaned focus: after a click
/// that no focusable widget claimed — a board square, a button, a text field
/// dropping focus on tap-outside — the primary focus falls back to the
/// enclosing route scope, which sits *above* this Focus in the tree. Key
/// events are dispatched from the primary focus upwards, so nothing in here
/// sees them and every trainer key goes dead until the user happens to click
/// something focusable. [keyboardFocusIsOrphaned] detects exactly that state
/// and the scope takes focus back (see [_healFocus]).
///
/// [onKeyEvent] must dispatch through `handleKeyBindings` (or otherwise guard
/// with `isTextInputFocused()`) so keys never fire while the user is typing a
/// move. Deliberately no [Shortcuts]/[Actions] support: a `Shortcuts` ancestor
/// intercepts keys before descendant text fields see them, which once made
/// "e" un-typeable in the tactics import form.
/// True when no focusable node owns the keyboard: the primary focus is a
/// [FocusScopeNode] (or gone), so key events are delivered to the route and
/// nothing below it. This is the state a desktop click leaves behind whenever
/// the thing clicked cannot take focus.
bool keyboardFocusIsOrphaned() {
  final primary = FocusManager.instance.primaryFocus;
  return primary == null || primary is FocusScopeNode;
}

class TrainerKeyboardScope extends StatefulWidget {
  /// Handles panel-level keys. Receives events bubbled from focused
  /// descendants (board, move input, buttons).
  final KeyEventResult Function(FocusNode node, KeyEvent event) onKeyEvent;

  /// Whether the scope itself holds primary focus. See the class doc.
  final bool holdsFocus;

  /// Required when [holdsFocus] is true so tap-to-refocus can restore focus to
  /// the scope after the user clicks elsewhere.
  final FocusNode? focusNode;

  final Widget child;

  const TrainerKeyboardScope({
    super.key,
    required this.onKeyEvent,
    required this.child,
    this.holdsFocus = false,
    this.focusNode,
  }) : assert(
         !holdsFocus || focusNode != null,
         'holdsFocus requires a focusNode for tap-to-refocus',
       );

  @override
  State<TrainerKeyboardScope> createState() => _TrainerKeyboardScopeState();
}

class _TrainerKeyboardScopeState extends State<TrainerKeyboardScope> {
  /// Take focus back when a click left it orphaned. Deferred to a microtask
  /// because the unfocus this repairs happens during the same pointer-down
  /// dispatch (a `TextField`'s tap-outside handler), so the focus state is
  /// only settled once the event has finished routing.
  void _onPointerDown(PointerDownEvent _) {
    scheduleMicrotask(() {
      if (!mounted) return;
      final node = widget.focusNode;
      if (node == null || !node.canRequestFocus) return;
      if (!keyboardFocusIsOrphaned()) return;
      node.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget content = widget.child;

    // In holds-focus mode, a click anywhere on the panel restores focus to the
    // scope so navigation shortcuts keep working after clicking around. A
    // Listener, not a GestureDetector: a button or a tab under the pointer
    // wins the gesture arena, and the tap callback this used to use then never
    // fired — which is how clicking a control in the panel could kill the
    // keyboard.
    if (widget.holdsFocus) {
      content = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        child: content,
      );
    }

    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.holdsFocus,
      // When the scope must not steal typing focus, it stays an ancestor-only
      // key handler: it still receives bubbled events but never holds focus.
      canRequestFocus: widget.holdsFocus,
      onKeyEvent: widget.onKeyEvent,
      child: content,
    );
  }
}
