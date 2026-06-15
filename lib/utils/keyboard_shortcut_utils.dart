import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Returns true when the primary focus is on a text-editing widget.
bool isTextInputFocused() {
  final primaryFocus = FocusManager.instance.primaryFocus;
  if (primaryFocus == null) return false;
  final context = primaryFocus.context;
  if (context == null) return false;
  if (context.widget is EditableText) return true;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// True when Ctrl (Windows/Linux) or Cmd (macOS) is held.
bool get isPrimaryModifierPressed {
  final keyboard = HardwareKeyboard.instance;
  return keyboard.isControlPressed || keyboard.isMetaPressed;
}

/// True when no Ctrl/Cmd/Shift/Alt modifiers are held (for bare letter keys).
bool get hasNoLetterModifiers {
  final keyboard = HardwareKeyboard.instance;
  return !isPrimaryModifierPressed &&
      !keyboard.isShiftPressed &&
      !keyboard.isAltPressed;
}
