import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/keyboard_shortcut_utils.dart';

/// Keyboard shortcuts for the repertoire screen, declared as [KeyBinding]s
/// and dispatched through [handleKeyBindings] — so none of them can fire
/// while a text field has focus.
///
/// The one exception is [onPasteFenFromClipboard] (Ctrl/Cmd+Shift+V), which
/// deliberately stays active in text fields and therefore uses
/// [CallbackShortcuts].
class RepertoireShortcuts extends StatelessWidget {
  const RepertoireShortcuts({
    super.key,
    required this.focusNode,
    required this.onPasteFenFromClipboard,
    required this.onUndo,
    required this.onToggleExpectimax,
    required this.onToggleLinesTab,
    required this.onCollapseBottomPane,
    required this.onFlip,
    required this.onToggleTrapTour,
    required this.onToggleEngine,
    required this.onGoBack,
    required this.onGoForward,
    required this.onGoToPreviousTrap,
    required this.onGoToNextTrap,
    this.onNextFinding,
    this.onPrevFinding,
    this.onDismissFinding,
    this.onFocusComment,
    this.autofocus = true,
    required this.child,
  });

  final FocusNode focusNode;
  final bool autofocus;

  final VoidCallback onPasteFenFromClipboard;
  final VoidCallback onUndo;
  final VoidCallback onToggleExpectimax;
  final VoidCallback onToggleLinesTab;

  /// Called on Escape when the bottom pane can be collapsed.
  /// Return true if the shortcut was handled.
  final bool Function() onCollapseBottomPane;

  final VoidCallback onFlip;

  /// Called on T to toggle the trap tour.
  /// Return true if the shortcut was handled.
  final bool Function() onToggleTrapTour;

  final VoidCallback onToggleEngine;
  final VoidCallback onGoBack;
  final VoidCallback onGoForward;

  /// Called on Shift+Left before [onGoBack]. Return true if trap nav handled.
  final bool Function() onGoToPreviousTrap;

  /// Called on Shift+Right before [onGoForward]. Return true if trap nav handled.
  final bool Function() onGoToNextTrap;

  /// N — next trap-tour stop when the tour is open, otherwise next finding
  /// in the audit findings panel.
  final bool Function()? onNextFinding;

  /// P — previous trap-tour stop when the tour is open, otherwise previous
  /// finding in the audit findings panel.
  final bool Function()? onPrevFinding;

  /// D — dismiss current finding in the audit findings panel.
  final bool Function()? onDismissFinding;

  /// C — focus the annotation panel's comment field for the current move.
  /// Return true if a comment field was focused.
  final bool Function()? onFocusComment;

  final Widget child;

  List<KeyBinding> get _keyBindings => [
    // Ctrl+Z lives here (not in CallbackShortcuts) so text fields keep
    // their native undo while typing.
    KeyBinding.run(LogicalKeyboardKey.keyZ, 'Undo', onUndo, control: true),
    KeyBinding.run(
      LogicalKeyboardKey.keyX,
      'Toggle expectimax bar',
      onToggleExpectimax,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.keyL,
      'Toggle lines panel',
      onToggleLinesTab,
    ),
    KeyBinding(
      LogicalKeyboardKey.escape,
      'Collapse bottom pane',
      onCollapseBottomPane,
    ),
    KeyBinding.run(LogicalKeyboardKey.keyF, 'Flip board', onFlip),
    KeyBinding(LogicalKeyboardKey.keyT, 'Toggle trap tour', onToggleTrapTour),
    KeyBinding.run(LogicalKeyboardKey.keyE, 'Toggle engine', onToggleEngine),
    KeyBinding(
      LogicalKeyboardKey.keyN,
      'Next trap stop / finding',
      () => onNextFinding?.call() ?? false,
    ),
    KeyBinding(
      LogicalKeyboardKey.keyP,
      'Previous trap stop / finding',
      () => onPrevFinding?.call() ?? false,
    ),
    KeyBinding(
      LogicalKeyboardKey.keyD,
      'Dismiss finding',
      () => onDismissFinding?.call() ?? false,
    ),
    KeyBinding(
      LogicalKeyboardKey.keyC,
      'Comment current move',
      () => onFocusComment?.call() ?? false,
    ),
    // Shift+←/→ jump between traps, falling back to plain navigation when
    // there is no trap to jump to.
    KeyBinding.run(
      LogicalKeyboardKey.arrowLeft,
      'Previous trap',
      () {
        if (!onGoToPreviousTrap()) onGoBack();
      },
      shift: true,
      repeats: true,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.arrowRight,
      'Next trap',
      () {
        if (!onGoToNextTrap()) onGoForward();
      },
      shift: true,
      repeats: true,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.arrowLeft,
      'Back one move',
      onGoBack,
      repeats: true,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.arrowRight,
      'Forward one move',
      onGoForward,
      repeats: true,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(
          LogicalKeyboardKey.keyV,
          control: true,
          shift: true,
        ): onPasteFenFromClipboard,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true, shift: true):
            onPasteFenFromClipboard,
      },
      child: Focus(
        focusNode: focusNode,
        autofocus: autofocus,
        onKeyEvent: (node, event) => handleKeyBindings(_keyBindings, event),
        child: child,
      ),
    );
  }
}
