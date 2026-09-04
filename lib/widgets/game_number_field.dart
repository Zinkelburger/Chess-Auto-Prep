/// "Game [__] of N" jump box for the PGN viewer's game nav bar.
///
/// The counter *is* the input: type a game number, press Enter, and you are
/// on that game. No search, no result list, no "did you mean game 70?" row to
/// pick out of — searching by player or event is still one button over, but a
/// number you already know shouldn't have to go through it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';

/// Fits four digits; static so the bar's layout never shifts as the number
/// grows.
const _fieldWidth = 56.0;

/// Shared height for the **Game N of Total** box and the Search button
/// beside it, so the pair aligns in the nav bar and the opening-tree list.
const kGameNavControlHeight = 32.0;

class GameNumberField extends StatefulWidget {
  /// Focuses the most recently mounted box and selects its number, so a
  /// keyboard shortcut can land straight on "type the number you want".
  /// Returns false when none is on screen, letting the key fall through.
  static bool focusActive() {
    for (final state in _GameNumberFieldState._mounted.reversed) {
      if (state.mounted && state.widget.gameCount > 0) {
        state._focusAndSelect();
        return true;
      }
    }
    return false;
  }

  /// Index of the game on screen, 0-based (displayed as `currentIndex + 1`).
  final int currentIndex;

  /// How many games the current filter/sort holds.
  final int gameCount;

  /// Called with a 0-based index when a valid number is entered.
  final ValueChanged<int>? onGoToGame;

  /// Hover text for the whole control — the caller owns it because only it
  /// knows which ordering the numbers are counting in.
  final String? tooltip;

  const GameNumberField({
    super.key,
    required this.currentIndex,
    required this.gameCount,
    this.onGoToGame,
    this.tooltip,
  });

  @override
  State<GameNumberField> createState() => _GameNumberFieldState();
}

class _GameNumberFieldState extends State<GameNumberField> {
  /// Mounted boxes, oldest first; [GameNumberField.focusActive] targets the
  /// newest so a foreground viewer wins over a background one.
  static final List<_GameNumberFieldState> _mounted = [];

  late final TextEditingController _controller = TextEditingController(
    text: _currentText,
  );
  final FocusNode _focusNode = FocusNode(debugLabel: 'GameNumberField');

  String get _currentText =>
      widget.gameCount == 0 ? '' : '${widget.currentIndex + 1}';

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
    _focusNode.onKeyEvent = _handleFieldKey;
    _mounted.add(this);
  }

  @override
  void didUpdateWidget(GameNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow prev/next/auto-play, but never overwrite a number mid-typing.
    if (!_focusNode.hasFocus &&
        (widget.currentIndex != oldWidget.currentIndex ||
            widget.gameCount != oldWidget.gameCount)) {
      _resetText();
    }
  }

  @override
  void dispose() {
    _mounted.remove(this);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) {
      // Typing replaces the current number instead of appending to it.
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    } else {
      // Abandoned edit: the box is the counter again.
      _resetText();
    }
  }

  void _focusAndSelect() {
    _focusNode.requestFocus();
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  void _resetText() {
    if (_controller.text != _currentText) _controller.text = _currentText;
  }

  /// Escape abandons the edit and hands the keyboard back to whoever had it,
  /// so the board shortcuts work again on the very next key.
  KeyEventResult _handleFieldKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _resetText();
      node.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _submit(String raw) {
    final total = widget.gameCount;
    final n = int.tryParse(raw.trim());
    if (n == null || total == 0) {
      _resetText();
      return;
    }
    // Past either end means "the last one I have" rather than an error the
    // user has to decode — the number the box lands on says what happened.
    final target = n.clamp(1, total) - 1;
    _controller.text = '${target + 1}';
    // Hand the keyboard back so ←/→ move through the game again.
    _focusNode.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
    widget.onGoToGame?.call(target);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.gameCount > 0 && widget.onGoToGame != null;
    const labelStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);

    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide(color: color),
    );

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Game', style: labelStyle),
        const SizedBox(width: 6),
        SizedBox(
          width: _fieldWidth,
          height: kGameNavControlHeight,
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            enabled: enabled,
            textAlign: TextAlign.center,
            textAlignVertical: TextAlignVertical.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.go,
            onSubmitted: _submit,
            style: labelStyle,
            decoration: InputDecoration(
              isDense: true,
              // Explicit vertical centering is more reliable than the default
              // dense-field padding across Linux, Windows and macOS fonts.
              contentPadding: const EdgeInsets.symmetric(horizontal: 6),
              border: border(AppColors.outline),
              enabledBorder: border(AppColors.outline),
              disabledBorder: border(AppColors.outline),
              focusedBorder: border(theme.colorScheme.primary),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text('of ${widget.gameCount}', style: labelStyle),
      ],
    );

    final tooltip = widget.tooltip;
    return tooltip == null ? row : Tooltip(message: tooltip, child: row);
  }
}
