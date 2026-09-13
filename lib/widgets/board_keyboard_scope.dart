import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/keyboard_shortcut_utils.dart';
import 'training/move_input_widget.dart';

/// Keyboard home for a board, its move field, and its surrounding controls.
///
/// A real [FocusScope] keeps keys reachable when a field unfocuses. Events
/// stay in Flutter's focus tree, so dialogs, menus and other editors keep
/// their normal keyboard behavior. Wrap the whole screen, including panels
/// beside the board; provide the same bindings used by its shortcut tooltips.
///
/// Move characters take precedence over bare-letter commands while the move
/// field is enabled. The first character focuses that field and is consumed
/// exactly once; subsequent text uses Flutter's normal editing/IME pipeline.
class BoardKeyboardScope extends StatefulWidget {
  const BoardKeyboardScope({
    super.key,
    required this.moveInputKey,
    required this.bindings,
    required this.child,
    this.focusNode,
  });

  final GlobalKey<MoveInputWidgetState> moveInputKey;

  /// Read at dispatch time: callbacks may depend on a sibling panel's state.
  final List<KeyBinding> Function() bindings;
  final FocusScopeNode? focusNode;
  final Widget child;

  /// The field offers navigation keys before EditableText consumes them.
  static bool handleNavigationKey(BuildContext context, KeyEvent event) =>
      context
          .getInheritedWidgetOfExactType<_BoardKeyboardBindings>()
          ?.onNavigationKey(event) ??
      false;

  static bool contains(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_BoardKeyboardBindings>() != null;

  @override
  State<BoardKeyboardScope> createState() => _BoardKeyboardScopeState();
}

class _BoardKeyboardScopeState extends State<BoardKeyboardScope> {
  final _ownedNode = FocusScopeNode(debugLabel: 'board keyboard');
  FocusScopeNode get _node => widget.focusNode ?? _ownedNode;
  bool _active = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (active && !_active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_active ||
            ModalRoute.of(context)?.isCurrent == false) {
          return;
        }
        // Restore this mode's remembered focus, without taking it from an
        // editor the user selected in this same scope during the frame.
        if (!_node.hasFocus) _node.requestFocus();
      });
    }
    _active = active;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_active || ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext != null &&
        MenuController.maybeOf(focusedContext)?.isOpen == true) {
      return KeyEventResult.ignored;
    }
    if (!isTextInputFocused() &&
        event is KeyDownEvent &&
        !isPrimaryModifierPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        isChessMoveTextKey(event.logicalKey)) {
      final character = event.character;
      if (character != null &&
          widget.moveInputKey.currentState?.typeCharacter(character) == true) {
        return KeyEventResult.handled;
      }
    }
    // Escape from another editor unfocuses it into this scope. Requesting
    // focus on a FocusScopeNode instead would restore its remembered editor.
    return handleKeyBindings(widget.bindings(), event);
  }

  @override
  void dispose() {
    _ownedNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _BoardKeyboardBindings(
    onNavigationKey: (event) =>
        handleMoveInputNavigationKey(widget.bindings(), event),
    child: FocusScope(
      node: _node,
      canRequestFocus: _active,
      descendantsAreFocusable: _active,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    ),
  );
}

class _BoardKeyboardBindings extends InheritedWidget {
  const _BoardKeyboardBindings({
    required this.onNavigationKey,
    required super.child,
  });

  final bool Function(KeyEvent) onNavigationKey;

  @override
  bool updateShouldNotify(_BoardKeyboardBindings oldWidget) => true;
}
