import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/keyboard_shortcut_utils.dart';

/// Keyboard shortcuts for the repertoire screen.
///
/// Modifier chords use [CallbackShortcuts]; letter and navigation keys use
/// [Focus.onKeyEvent]. Shortcuts are suppressed while a text field has focus,
/// except [onPasteFenFromClipboard] (Ctrl/Cmd+Shift+V) which stays active in
/// text fields.
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

  void _invokeWhenNotTyping(VoidCallback action) {
    if (!isTextInputFocused()) action();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    if (isTextInputFocused()) return KeyEventResult.ignored;

    final keyboard = HardwareKeyboard.instance;

    if (event.logicalKey == LogicalKeyboardKey.keyG && hasNoLetterModifiers) {
      onOpenGeneration();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyA && hasNoLetterModifiers) {
      onOpenAudit();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyI && hasNoLetterModifiers) {
      onImportPgn();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyX && hasNoLetterModifiers) {
      onToggleExpectimax();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyL && hasNoLetterModifiers) {
      onToggleLinesTab();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (onCollapseBottomPane()) {
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.keyF && hasNoLetterModifiers) {
      onFlip();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyT && hasNoLetterModifiers) {
      if (onToggleTrapWalkthrough()) {
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.keyE && hasNoLetterModifiers) {
      onToggleEngine();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyN && hasNoLetterModifiers) {
      if (onNextFinding != null && onNextFinding!()) {
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.keyP && hasNoLetterModifiers) {
      if (onPrevFinding != null && onPrevFinding!()) {
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.keyD && hasNoLetterModifiers) {
      if (onDismissFinding != null && onDismissFinding!()) {
        return KeyEventResult.handled;
      }
    }

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
