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

/// One declarative keyboard shortcut: a key plus required modifiers, a
/// description (self-documentation — keep it in sync with the control's
/// [ShortcutTooltip]), and an action.
///
/// Always dispatch through [handleKeyBindings], which enforces the app-wide
/// safety rules — most importantly that **no binding ever fires while a text
/// field has focus**, so shortcuts can never eat typed characters. Never wire
/// single-key shortcuts through Flutter's [Shortcuts]/[CallbackShortcuts]
/// widgets: those intercept keys before descendant text fields see them
/// (that bug once made "e" un-typeable in the tactics import form).
class KeyBinding {
  const KeyBinding(
    this.key,
    this.description,
    this.action, {
    this.control = false,
    this.shift = false,
    this.repeats = false,
  });

  /// A binding that always consumes the key — for unconditional actions.
  factory KeyBinding.run(
    LogicalKeyboardKey key,
    String description,
    VoidCallback run, {
    bool control = false,
    bool shift = false,
    bool repeats = false,
  }) {
    return KeyBinding(
      key,
      description,
      () {
        run();
        return true;
      },
      control: control,
      shift: shift,
      repeats: repeats,
    );
  }

  final LogicalKeyboardKey key;

  /// What the binding does, e.g. `'Toggle engine'`.
  final String description;

  /// Runs on a match. Return true when the key was consumed; returning
  /// false lets later bindings (or the framework) handle it — use that for
  /// context-dependent shortcuts.
  final bool Function() action;

  /// Requires Ctrl (or Cmd on macOS) held. Bare-key bindings (`control` and
  /// [shift] false) only fire with *no* modifiers held, so `E` and `Ctrl+E`
  /// never collide.
  final bool control;
  final bool shift;

  /// Also fire on key-repeat while held (navigation keys).
  final bool repeats;

  /// True when this binding may fire while a chess *move-input* field owns
  /// focus: a bare key that can never appear in typed move text (SAN or
  /// UCI), so claiming it steals nothing from the move being typed. E.g.
  /// Space, S, P, J, arrows qualify; E, N, A, F, R, digits do not ("e4",
  /// "Nf3", "Rd1"). Used by [handleMoveInputNavigationKey].
  bool get safeWhileTypingMoves =>
      !control && !shift && !_chessMoveTextKeys.contains(key);

  bool _matches(LogicalKeyboardKey pressed, {required bool isRepeat}) {
    if (pressed != key) return false;
    if (isRepeat && !repeats) return false;
    final keyboard = HardwareKeyboard.instance;
    return control == isPrimaryModifierPressed &&
        shift == keyboard.isShiftPressed &&
        !keyboard.isAltPressed;
  }
}

/// Keys that can appear in typed chess-move text (SAN or UCI, matched
/// case-insensitively by the move input): files a–h, piece letters K/Q/R/N
/// (B is also a file), castling O, capture x, ranks 1–8, and "-"/"=" for
/// castling/promotion. A binding on any of these must never fire while a
/// move is being typed.
final Set<LogicalKeyboardKey> _chessMoveTextKeys = {
  LogicalKeyboardKey.keyA,
  LogicalKeyboardKey.keyB,
  LogicalKeyboardKey.keyC,
  LogicalKeyboardKey.keyD,
  LogicalKeyboardKey.keyE,
  LogicalKeyboardKey.keyF,
  LogicalKeyboardKey.keyG,
  LogicalKeyboardKey.keyH,
  LogicalKeyboardKey.keyK,
  LogicalKeyboardKey.keyN,
  LogicalKeyboardKey.keyO,
  LogicalKeyboardKey.keyQ,
  LogicalKeyboardKey.keyR,
  LogicalKeyboardKey.keyX,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.minus,
  LogicalKeyboardKey.equal,
};

/// Handler for `MoveInputWidget.onNavigationKey`: runs only the bindings
/// that are [KeyBinding.safeWhileTypingMoves], so shortcuts on non-move keys
/// (Space, S, J, arrows, …) keep working while a move is being typed, and
/// move characters ("e4", "Nf3") always type normally. Returns true when a
/// binding consumed the key — the move input then swallows it.
bool handleMoveInputNavigationKey(List<KeyBinding> bindings, KeyEvent event) {
  final isRepeat = event is KeyRepeatEvent;
  if (event is! KeyDownEvent && !isRepeat) return false;
  final safe = [
    for (final binding in bindings)
      if (binding.safeWhileTypingMoves) binding,
  ];
  return runKeyBindings(safe, event.logicalKey, isRepeat: isRepeat) ==
      KeyEventResult.handled;
}

/// Standard [Focus.onKeyEvent] dispatch for a screen's [KeyBinding] list.
///
/// Centralized guards: key-down (and opted-in repeat) events only, an exact
/// modifier match per binding, and — non-negotiable — nothing fires while a
/// text field has focus, so bindings can never swallow typing.
KeyEventResult handleKeyBindings(List<KeyBinding> bindings, KeyEvent event) {
  final isRepeat = event is KeyRepeatEvent;
  if (event is! KeyDownEvent && !isRepeat) return KeyEventResult.ignored;
  if (isTextInputFocused()) return KeyEventResult.ignored;
  return runKeyBindings(bindings, event.logicalKey, isRepeat: isRepeat);
}

/// Low-level matcher behind [handleKeyBindings]: runs the first binding
/// matching [key] under the current modifier state. No text-input guard —
/// the only callers that may use this directly are ones with an explicit
/// focus contract of their own (e.g. the tactics move-input bridge, where
/// the text field itself forwards the keys and swallows what's claimed).
KeyEventResult runKeyBindings(
  List<KeyBinding> bindings,
  LogicalKeyboardKey key, {
  bool isRepeat = false,
}) {
  for (final binding in bindings) {
    if (binding._matches(key, isRepeat: isRepeat) && binding.action()) {
      return KeyEventResult.handled;
    }
  }
  return KeyEventResult.ignored;
}
