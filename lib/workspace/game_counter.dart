import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/listening_state.dart';
import '../ui/theme.dart';
import 'document_session.dart';
import 'game_ordering.dart';
import '../ui/app_keys.dart';

/// `‹ [n] of N ›` under the board: which game of the open file is showing,
/// with the number typeable to jump. Nothing when the document is not one
/// game of a file, so a merged repertoire chapter leaves the row out.
class GameCounter extends StatefulWidget {
  const GameCounter({super.key, required this.session, this.ordering});
  final GameOrdering? ordering;

  final DocumentSession session;

  @override
  State<GameCounter> createState() => _GameCounterState();
}

class _GameCounterState extends State<GameCounter>
    with ListeningState<GameCounter> {
  final _number = TextEditingController();
  final _focus = FocusNode();

  @override
  Listenable listenableOf(GameCounter widget) =>
      Listenable.merge([widget.session, widget.ordering]);

  @override
  void initState() {
    super.initState();
    changed();
  }

  @override
  void dispose() {
    _focus.dispose();
    _number.dispose();
    super.dispose();
  }

  /// The box shows the game on the board unless the user is typing in it.
  @override
  void changed() {
    if (!_focus.hasFocus) _show();
  }

  List<int> get _order =>
      widget.ordering?.gameOrder ??
      List.generate(widget.session.gameCount ?? 0, (i) => i);
  int? get _at {
    if (widget.session.game == null) return null;
    final index = _order.indexOf(widget.session.game!);
    return index < 0 ? null : index;
  }

  void _show() {
    final at = _at;
    final text = at == null ? '' : '${at + 1}';
    if (_number.text != text) _number.text = text;
  }

  /// Enter goes to the number typed, or back to the one it was when the
  /// file has no such game. The focus is given up either way; it lets go a
  /// turn later, so the box is put right here rather than left to it.
  void _jump(String text) {
    final number = int.tryParse(text.trim());
    if (number != null && number > 0 && number <= _order.length) {
      widget.session.showGame(_order[number - 1]);
    }
    _focus.unfocus();
    _show();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.session, widget.ordering]),
      builder: (context, _) {
        final at = _at;
        final total = _order.length;
        if (widget.session.game == null) return const SizedBox.shrink();
        final text = Theme.of(context).textTheme;
        final previous = total == 0 || at == 0
            ? null
            : () => widget.session.showGame(
                _order[at == null ? total - 1 : at - 1],
              );
        final next = total == 0 || at == total - 1
            ? null
            : () => widget.session.showGame(_order[at == null ? 0 : at + 1]);
        // Whole beside the move field on a 280-pixel board. Narrower, `of N`
        // is cut short first, then the steps go (↑ and ↓ still walk), so
        // the row never spills.
        return LayoutBuilder(
          builder: (context, room) {
            final steps =
                room.maxWidth >=
                2 * _stepWidth + gameNumberWidth + Space.s + Space.xl;
            final number = min(
              gameNumberWidth,
              max(0.0, room.maxWidth - Space.s),
            );
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (steps)
                  _step(
                    Icons.chevron_left,
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
                  _step(
                    Icons.chevron_right,
                    AppKey.nextGame.tip('Next game'),
                    next,
                  ),
              ],
            );
          },
        );
      },
    );
  }

  /// How wide a step's button is at the small icon size.
  static const _stepWidth = IconSize.menu + 2 * Space.s;

  /// A step to the game before or after, at the small icon size the
  /// engine's header uses, so the counter fits beside the move field.
  Widget _step(IconData icon, String tooltip, VoidCallback? onPressed) =>
      IconButton(
        icon: Icon(icon, size: IconSize.menu),
        tooltip: tooltip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
      );

  /// The game's number, typed over to jump; the enter key goes there.
  Widget _numberBox(TextTheme text) => TextField(
    controller: _number,
    focusNode: _focus,
    textAlign: TextAlign.center,
    style: text.bodySmall,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
