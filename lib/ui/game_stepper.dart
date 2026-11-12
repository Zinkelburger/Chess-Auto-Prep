import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icons.dart';
import 'app_keys.dart';
import 'listening_state.dart';
import 'theme.dart';
import 'tool_button.dart';

/// `‹ [n] of N ›`: which of a file's games is showing, with the number
/// typeable to jump. [at] counts from 0 and is null when the game showing
/// is none of them; [onShow] is asked for a game by the same count.
class GameStepper extends StatefulWidget {
  const GameStepper({
    super.key,
    required this.at,
    required this.total,
    required this.onShow,
    this.alignment = MainAxisAlignment.center,
  });

  final int? at;
  final int total;
  final ValueChanged<int> onShow;

  /// Where the row sits in the width it is given.
  final MainAxisAlignment alignment;

  @override
  State<GameStepper> createState() => _GameStepperState();
}

class _GameStepperState extends State<GameStepper>
    with ListeningState<GameStepper> {
  final _number = TextEditingController();
  final _focus = FocusNode();

  /// Whether the box holds what the user is typing rather than [at].
  bool _typing = false;

  @override
  void initState() {
    super.initState();
    _show();
  }

  /// The box shows the game showing unless the user is typing in it.
  @override
  void didUpdateWidget(GameStepper old) {
    super.didUpdateWidget(old);
    if (!_typing) _show();
  }

  @override
  void dispose() {
    stopListening();
    _focus.dispose();
    _number.dispose();
    super.dispose();
  }

  @override
  Listenable listenableOf(GameStepper widget) => _focus;

  @override
  void changed() {
    if (_focus.hasFocus) return;
    _typing = false;
    _show();
  }

  void _show() {
    final at = widget.at;
    final text = at == null ? '' : '${at + 1}';
    if (_number.text != text) _number.text = text;
  }

  /// Enter goes to the number typed, or back to the one it was when the
  /// file has no such game. The focus is given up either way; it lets go a
  /// turn later, so the box is put right here rather than left to it.
  void _jump(String text) {
    final number = int.tryParse(text.trim());
    _typing = false;
    if (number != null && number > 0 && number <= widget.total) {
      widget.onShow(number - 1);
    }
    _focus.unfocus();
    _show();
  }

  @override
  Widget build(BuildContext context) {
    final at = widget.at;
    final total = widget.total;
    final text = Theme.of(context).textTheme;
    final previous = total == 0 || at == 0
        ? null
        : () => widget.onShow(at == null ? total - 1 : at - 1);
    final next = total == 0 || at == total - 1
        ? null
        : () => widget.onShow(at == null ? 0 : at + 1);
    // Whole beside the move field on a 280-pixel board. Narrower, `of N`
    // is cut short first, then the steps go (↑ and ↓ still walk), so
    // the row never spills.
    return LayoutBuilder(
      builder: (context, room) {
        final steps =
            room.maxWidth >=
            2 * _stepWidth + gameNumberWidth + Space.s + Space.xl;
        final number = min(gameNumberWidth, max(0.0, room.maxWidth - Space.s));
        return Row(
          mainAxisAlignment: widget.alignment,
          children: [
            if (steps)
              _step(
                AppIcons.previous,
                AppKey.previousGame.tip('Previous game'),
                previous,
              ),
            SizedBox(width: number, child: _numberBox(text)),
            const SizedBox(width: Space.s),
            Flexible(
              child: Text(
                'of $total',
                style: text.bodySmall,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (steps)
              _step(AppIcons.next, AppKey.nextGame.tip('Next game'), next),
          ],
        );
      },
    );
  }

  /// How wide a step's button is at the small icon size.
  static const _stepWidth = IconSize.menu + 2 * Space.s;

  /// A step to the game before or after, at the small icon size the
  /// engine's header uses, so the counter fits beside the move field.
  Widget _step(IconData icon, String tooltip, VoidCallback? onPressed) =>
      ToolButton(
        icon: icon,
        tooltip: tooltip,
        size: IconSize.menu,
        onPressed: onPressed,
      );

  /// The game's number, typed over to jump; the enter key goes there.
  Widget _numberBox(TextTheme text) => TextField(
    controller: _number,
    focusNode: _focus,
    textAlign: TextAlign.center,
    style: text.bodySmall,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    onChanged: (_) => _typing = true,
    onSubmitted: _jump,
    onTapOutside: (_) => _focus.unfocus(),
    decoration: const InputDecoration(
      isDense: true,
      contentPadding: EdgeInsets.symmetric(
        horizontal: Space.xs,
        vertical: Space.xs,
      ),
      border: OutlineInputBorder(),
    ),
  );
}
