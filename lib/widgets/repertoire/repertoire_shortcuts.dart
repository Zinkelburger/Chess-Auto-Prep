import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keyboard shortcuts for the repertoire screen.
///
/// Uses [CallbackShortcuts] for modifier chords and [Focus.onKeyEvent] for
/// single-key bindings that must not fire when Ctrl/Cmd/Shift/Alt are held.
/// Most shortcuts are suppressed while an [EditableText] has focus;
/// [onPasteFenFromClipboard] (Ctrl/Cmd+Shift+V) remains active in text fields.
class RepertoireShortcuts extends StatelessWidget {
  const RepertoireShortcuts({
    super.key,
    required this.focusNode,
    required this.onPasteFenFromClipboard,
    required this.onUndo,
    required this.onOpenGeneration,
    required this.onOpenAudit,
    required this.onImportPgn,
    required this.onToggleExpectimax,
    required this.onToggleLinesTab,
    required this.onToggleJobsPane,
    required this.onToggleFindingsPane,
    required this.onToggleLinesPane,
    required this.onCollapseBottomPane,
    required this.onFlip,
    required this.onToggleTrapWalkthrough,
    required this.onToggleEngine,
    required this.onGoBack,
    required this.onGoForward,
    required this.onGoToPreviousTrap,
    required this.onGoToNextTrap,
    this.onNextFinding,
    this.onPrevFinding,
    this.onDismissFinding,
    this.autofocus = true,
    required this.child,
  });

  final FocusNode focusNode;
  final bool autofocus;

  final VoidCallback onPasteFenFromClipboard;
  final VoidCallback onUndo;
  final VoidCallback onOpenGeneration;
  final VoidCallback onOpenAudit;
  final VoidCallback onImportPgn;
  final VoidCallback onToggleExpectimax;
  final VoidCallback onToggleLinesTab;
  final VoidCallback onToggleJobsPane;
  final VoidCallback onToggleFindingsPane;
  final VoidCallback onToggleLinesPane;

  /// Called on Escape when the bottom pane can be collapsed.
  /// Return true if the shortcut was handled.
  final bool Function() onCollapseBottomPane;

  final VoidCallback onFlip;

  /// Called on T when the current position is a trap.
  /// Return true if the shortcut was handled.
  final bool Function() onToggleTrapWalkthrough;

  final VoidCallback onToggleEngine;
  final VoidCallback onGoBack;
  final VoidCallback onGoForward;

  /// Called on Shift+Left before [onGoBack]. Return true if trap nav handled.
  final bool Function() onGoToPreviousTrap;

  /// Called on Shift+Right before [onGoForward]. Return true if trap nav handled.
  final bool Function() onGoToNextTrap;

  /// N — next finding in the audit findings panel.
  final bool Function()? onNextFinding;

  /// P — previous finding in the audit findings panel.
  final bool Function()? onPrevFinding;

  /// D — dismiss current finding in the audit findings panel.
  final bool Function()? onDismissFinding;

  final Widget child;

  static bool get isTextInputFocused {
    final primaryFocus = FocusManager.instance.primaryFocus;
    return primaryFocus?.context?.widget is EditableText;
  }

  static bool get isPrimaryModifierPressed {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isControlPressed || keyboard.isMetaPressed;
  }

  static bool get hasNoLetterModifiers {
    final keyboard = HardwareKeyboard.instance;
    return !isPrimaryModifierPressed &&
        !keyboard.isShiftPressed &&
        !keyboard.isAltPressed;
  }

  void _invokeWhenNotTyping(VoidCallback action) {
    if (!isTextInputFocused) action();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    if (isTextInputFocused) return KeyEventResult.ignored;

    final keyboard = HardwareKeyboard.instance;

    // 'G' key — open generation config in Jobs tab
    if (event.logicalKey == LogicalKeyboardKey.keyG && hasNoLetterModifiers) {
      onOpenGeneration();
      return KeyEventResult.handled;
    }

    // 'A' key — open audit config in Jobs tab
    if (event.logicalKey == LogicalKeyboardKey.keyA && hasNoLetterModifiers) {
      onOpenAudit();
      return KeyEventResult.handled;
    }

    // 'I' key — import PGN into repertoire
    if (event.logicalKey == LogicalKeyboardKey.keyI && hasNoLetterModifiers) {
      onImportPgn();
      return KeyEventResult.handled;
    }

    // 'X' key — toggle expectimax bar
    if (event.logicalKey == LogicalKeyboardKey.keyX && hasNoLetterModifiers) {
      onToggleExpectimax();
      return KeyEventResult.handled;
    }

    // 'L' key — toggle Lines tab in tools column
    if (event.logicalKey == LogicalKeyboardKey.keyL && hasNoLetterModifiers) {
      onToggleLinesTab();
      return KeyEventResult.handled;
    }

    // '1' key — toggle Jobs in bottom pane
    if (event.logicalKey == LogicalKeyboardKey.digit1 &&
        !isPrimaryModifierPressed &&
        !keyboard.isShiftPressed) {
      onToggleJobsPane();
      return KeyEventResult.handled;
    }

    // '2' key — toggle Findings in bottom pane
    if (event.logicalKey == LogicalKeyboardKey.digit2 &&
        !isPrimaryModifierPressed &&
        !keyboard.isShiftPressed) {
      onToggleFindingsPane();
      return KeyEventResult.handled;
    }

    // '3' key — toggle Lines in bottom pane
    if (event.logicalKey == LogicalKeyboardKey.digit3 &&
        !isPrimaryModifierPressed &&
        !keyboard.isShiftPressed) {
      onToggleLinesPane();
      return KeyEventResult.handled;
    }

    // Escape — collapse bottom pane
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (onCollapseBottomPane()) {
        return KeyEventResult.handled;
      }
    }

    // 'F' key — flip the board
    if (event.logicalKey == LogicalKeyboardKey.keyF && hasNoLetterModifiers) {
      onFlip();
      return KeyEventResult.handled;
    }

    // 'T' key — toggle trap walkthrough at a trap position
    if (event.logicalKey == LogicalKeyboardKey.keyT && hasNoLetterModifiers) {
      if (onToggleTrapWalkthrough()) {
        return KeyEventResult.handled;
      }
    }

    // 'E' key — toggle engine
    if (event.logicalKey == LogicalKeyboardKey.keyE && hasNoLetterModifiers) {
      onToggleEngine();
      return KeyEventResult.handled;
    }

    // 'N' key — next finding (findings panel)
    if (event.logicalKey == LogicalKeyboardKey.keyN && hasNoLetterModifiers) {
      if (onNextFinding != null && onNextFinding!()) {
        return KeyEventResult.handled;
      }
    }

    // 'P' key — previous finding (findings panel)
    if (event.logicalKey == LogicalKeyboardKey.keyP && hasNoLetterModifiers) {
      if (onPrevFinding != null && onPrevFinding!()) {
        return KeyEventResult.handled;
      }
    }

    // 'D' key — dismiss current finding (findings panel)
    if (event.logicalKey == LogicalKeyboardKey.keyD && hasNoLetterModifiers) {
      if (onDismissFinding != null && onDismissFinding!()) {
        return KeyEventResult.handled;
      }
    }

    // Arrow keys — always through controller (single source of truth).
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (keyboard.isShiftPressed && onGoToPreviousTrap()) {
        return KeyEventResult.handled;
      }
      onGoBack();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (keyboard.isShiftPressed && onGoToNextTrap()) {
        return KeyEventResult.handled;
      }
      onGoForward();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
            onPasteFenFromClipboard,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true, shift: true):
            onPasteFenFromClipboard,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: false):
            () => _invokeWhenNotTyping(onUndo),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: false):
            () => _invokeWhenNotTyping(onUndo),
      },
      child: Focus(
        focusNode: focusNode,
        autofocus: autofocus,
        onKeyEvent: _handleKeyEvent,
        child: child,
      ),
    );
  }
}
