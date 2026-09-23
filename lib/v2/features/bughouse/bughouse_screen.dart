import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/theme.dart';
import 'archive_moves.dart';
import 'board_setup.dart';
import 'bughouse_lab.dart';
import 'lab_panel.dart';
import 'table_boards.dart';
import 'table_search.dart';

/// The Bughouse lab on one screen, as the BughouseDB page lays it out: the
/// two boards and their setup boxes on the left, the question, the status
/// and each board's scored moves on the right. The boards take what the
/// window leaves, between [labBoardMin] and [labBoardMax].
///
/// ← → step the board last moved or stepped on, Home and End go to its
/// ends; a text box keeps those keys while it has the focus.
class BughouseScreen extends StatelessWidget {
  const BughouseScreen({
    super.key,
    required this.lab,
    required this.search,
    required this.archive,
    this.windowKeys = const {},
  });

  final BughouseLab lab;
  final TableSearch search;
  final ArchiveMoves archive;

  /// The window's own keys, which the shell binds in every mode.
  final Map<ShortcutActivator, VoidCallback> windowKeys;

  /// As large as both boards can be side by side beside the panel, and
  /// under the height the rest of the left column needs.
  static double boardSize(BoxConstraints box) {
    final byWidth =
        (box.maxWidth - labPanelMinWidth - labColumnGap - labBoardGap) / 2;
    final byHeight = box.maxHeight - labBoardChrome;
    return math.min(byWidth, byHeight).clamp(labBoardMin, labBoardMax);
  }

  @override
  Widget build(BuildContext context) {
    return _LabKeys(
      lab: lab,
      windowKeys: windowKeys,
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: LayoutBuilder(
          builder: (context, box) {
            final size = boardSize(box);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Scrolls only when the window is shorter than the least
                // the column needs; at any ordinary size it fits.
                SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TableBoards(lab: lab, boardSize: size),
                      const SizedBox(height: Space.s),
                      BoardSetup(lab: lab, boardSize: size),
                    ],
                  ),
                ),
                const SizedBox(width: labColumnGap),
                Expanded(
                  child: LabPanel(lab: lab, search: search, archive: archive),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The lab's keys, and the window's, wherever the focus is inside it —
/// unless the user is typing, when the keys are the text box's.
class _LabKeys extends StatelessWidget {
  const _LabKeys({
    required this.lab,
    required this.windowKeys,
    required this.child,
  });

  final BughouseLab lab;
  final Map<ShortcutActivator, VoidCallback> windowKeys;
  final Widget child;

  Map<ShortcutActivator, VoidCallback> get _bindings => {
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () => lab.step(-1),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () => lab.step(1),
    const SingleActivator(LogicalKeyboardKey.home): lab.toStart,
    const SingleActivator(LogicalKeyboardKey.end): lab.toEnd,
    const SingleActivator(LogicalKeyboardKey.escape): () =>
        lab.preview.value = null,
    ...windowKeys,
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
  Widget build(BuildContext context) =>
      Focus(autofocus: true, onKeyEvent: _onKey, child: child);
}
