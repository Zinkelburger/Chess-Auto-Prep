import 'package:flutter/material.dart';

/// Shared keyboard/focus plumbing for the board trainers (Repertoire, Tactics).
///
/// Both trainers pair a chess board + a type-a-move text field + panel-level
/// keyboard shortcuts. Getting the focus contract subtly wrong breaks either
/// typing (an ancestor steals the keystrokes) or shortcuts (nothing is focused
/// to receive them). This widget centralises that contract so each trainer only
/// has to supply its own key meanings via [onKeyEvent] (and optional
/// [shortcuts]/[actions]).
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
/// [onKeyEvent] should guard trainer-specific keys with `isTextInputFocused()`
/// so they don't fire while the user is typing a move (see
/// `keyboard_shortcut_utils.dart`).
class TrainerKeyboardScope extends StatelessWidget {
  /// Handles panel-level keys. Receives events bubbled from focused
  /// descendants (board, move input, buttons).
  final KeyEventResult Function(FocusNode node, KeyEvent event) onKeyEvent;

  /// Whether the scope itself holds primary focus. See the class doc.
  final bool holdsFocus;

  /// Required when [holdsFocus] is true so tap-to-refocus can restore focus to
  /// the scope after the user clicks elsewhere.
  final FocusNode? focusNode;

  /// Optional declarative shortcuts (paired with [actions]), wrapped outside
  /// the [Focus] so they resolve regardless of the mode above.
  final Map<ShortcutActivator, Intent>? shortcuts;
  final Map<Type, Action<Intent>>? actions;

  final Widget child;

  const TrainerKeyboardScope({
    super.key,
    required this.onKeyEvent,
    required this.child,
    this.holdsFocus = false,
    this.focusNode,
    this.shortcuts,
    this.actions,
  }) : assert(
         !holdsFocus || focusNode != null,
         'holdsFocus requires a focusNode for tap-to-refocus',
       ),
       assert(
         (shortcuts == null) == (actions == null),
         'shortcuts and actions must be provided together',
       );

  @override
  Widget build(BuildContext context) {
    Widget content = child;

    // In holds-focus mode, a tap anywhere on the panel restores focus to the
    // scope so navigation shortcuts keep working after clicking around.
    if (holdsFocus) {
      content = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => focusNode?.requestFocus(),
        child: content,
      );
    }

    Widget result = Focus(
      focusNode: focusNode,
      autofocus: holdsFocus,
      // When the scope must not steal typing focus, it stays an ancestor-only
      // key handler: it still receives bubbled events but never holds focus.
      canRequestFocus: holdsFocus,
      onKeyEvent: onKeyEvent,
      child: content,
    );

    if (shortcuts != null) {
      result = Shortcuts(
        shortcuts: shortcuts!,
        child: Actions(actions: actions!, child: result),
      );
    }

    return result;
  }
}
