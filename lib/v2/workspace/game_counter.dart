import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/app_action.dart';
import '../ui/listening_state.dart';
import '../ui/theme.dart';
import 'document_session.dart';
import 'game_ordering.dart';

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
    if (number != null && number > 0 && number <= _order.length)
      widget.session.showGame(_order[number - 1]);
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
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left, size: IconSize.action),
              tooltip: withKey('Previous game', '↑'),
              onPressed: total == 0 || at == 0
                  ? null
                  : () => widget.session.showGame(
                      _order[at == null ? total - 1 : at - 1],
                    ),
              visualDensity: VisualDensity.compact,
            ),
            SizedBox(width: gameNumberWidth, child: _numberBox(text)),
            const SizedBox(width: Space.s),
            Text('of $total', style: text.bodySmall),
            IconButton(
              icon: const Icon(Icons.chevron_right, size: IconSize.action),
              tooltip: withKey('Next game', '↓'),
              onPressed: total == 0 || at == total - 1
                  ? null
                  : () => widget.session.showGame(
                      _order[at == null ? 0 : at + 1],
                    ),
              visualDensity: VisualDensity.compact,
            ),
          ],
        );
      },
    );
  }

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
