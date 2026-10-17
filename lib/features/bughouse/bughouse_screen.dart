import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/app_keys.dart';
import '../../ui/theme.dart';
import 'bughouse_lab.dart';
import 'lab_engine.dart';
import 'lab_panel.dart';
import 'table_boards.dart';

/// The Bughouse mode: board 1 alone or both boards on the left, the engine
/// and (with one board) the moves on the right. The boards take what the
/// window leaves.
///
/// ← → step the board last moved or stepped on, Home and End go to its
/// ends, E switches the engine.
class BughouseScreen extends StatelessWidget {
  const BughouseScreen({
    super.key,
    required this.lab,
    required this.engine,
    this.windowKeys = const {},
  });

  final BughouseLab lab;
  final LabEngine engine;

  /// The window's own keys, which the shell binds in every mode.
  final Map<ShortcutActivator, VoidCallback> windowKeys;

  /// As large as the boards on screen can be beside the panel, and under
  /// the height the hands (a square tall, a + and a − row) and, with two
  /// boards, the chrome need.
  static double boardSize(BoxConstraints box, LabBoards boards) {
    const hands = 2 * (2 * labStepHeight + labSeatPadding);
    final width = box.maxWidth - labPanelMinWidth - labColumnGap;
    return switch (boards) {
      LabBoards.one =>
        math
            .min(width, (box.maxHeight - hands) / (1 + 2 / 8))
            .clamp(labBoardMin, labOneBoardMax),
      LabBoards.two =>
        math
            .min(
              (width - labBoardGap) / 2,
              (box.maxHeight - hands - labBoardChrome) / (1 + 2 / 8),
            )
            .clamp(labBoardMin, labBoardMax),
    };
  }

  @override
  Widget build(BuildContext context) {
    return _LabKeys(
      lab: lab,
      engine: engine,
      windowKeys: windowKeys,
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: LayoutBuilder(
          builder: (context, box) => ListenableBuilder(
            listenable: lab,
            builder: (context, _) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Scrolls only when the window is shorter than the least
                // the column needs; at any ordinary size it fits.
                SingleChildScrollView(
                  child: TableBoards(
                    lab: lab,
                    boardSize: boardSize(box, lab.boards),
                  ),
                ),
                const SizedBox(width: labColumnGap),
                Expanded(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: labPanelMaxWidth,
                      ),
                      child: LabPanel(lab: lab, engine: engine),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The mode's keys, and the window's, wherever the focus is inside it —
/// unless the user is typing, when the keys are the text box's.
class _LabKeys extends StatefulWidget {
  const _LabKeys({
    required this.lab,
    required this.engine,
    required this.windowKeys,
    required this.child,
  });

  final BughouseLab lab;
  final LabEngine engine;
  final Map<ShortcutActivator, VoidCallback> windowKeys;
  final Widget child;

  @override
  State<_LabKeys> createState() => _LabKeysState();
}

class _LabKeysState extends State<_LabKeys> {
  final _focus = FocusNode(debugLabel: 'Bughouse');

  BughouseLab get lab => widget.lab;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Map<ShortcutActivator, VoidCallback> get _bindings => {
    ...AppKey.stepBack.bind(() => lab.step(-1)),
    ...AppKey.stepForward.bind(() => lab.step(1)),
    ...AppKey.firstMove.bind(lab.toStart),
    ...AppKey.lastMove.bind(lab.toEnd),
    ...AppKey.closePreview.bind(() => lab.preview.value = null),
    ...widget.windowKeys,
    ...AppKey.bughouseEngine.bind(widget.engine.toggle),
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _typing) return KeyEventResult.ignored;
    for (final MapEntry(key: activator, value: run) in _bindings.entries) {
      if (activator.accepts(event, HardwareKeyboard.instance)) {
        run();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  bool get _typing {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused != null &&
        focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _onKey,
    child: widget.child,
  );
}
