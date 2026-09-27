import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/theme.dart';
import 'archive_moves.dart';
import 'board_setup.dart';
import 'bughouse_lab.dart';
import 'lab_panel.dart';
import 'matches.dart';
import 'match_panel.dart';
import 'table_boards.dart';
import 'table_search.dart';

/// The Bughouse lab: boards and FICS continuations on the left, compact engine
/// tables on the right. Position editing is collapsed; Matches is in Actions.
/// The boards take what the
/// window leaves, between [labBoardMin] and [labBoardMax].
///
/// ← → step the board last moved or stepped on, Home and End go to its
/// ends, E switches the engine; a text box keeps those keys while it has
/// the focus.
class BughouseScreen extends StatelessWidget {
  const BughouseScreen({
    super.key,
    required this.lab,
    required this.search,
    required this.archive,
    required this.matches,
    this.windowKeys = const {},
  });

  final BughouseLab lab;
  final TableSearch search;
  final ArchiveMoves archive;
  final Matches matches;

  /// The window's own keys, which the shell binds in every mode.
  final Map<ShortcutActivator, VoidCallback> windowKeys;

  /// As large as both boards can be side by side beside the panel, and
  /// under the height the rest of the left column needs: the two seat rows,
  /// each a square tall and padded, and the chrome under them.
  static double boardSize(BoxConstraints box) {
    final byWidth =
        (box.maxWidth - labPanelMinWidth - labColumnGap - labBoardGap) / 2;
    final byHeight =
        (box.maxHeight - labBoardChrome - 2 * labSeatPadding) / (1 + 2 / 8);
    return math.min(byWidth, byHeight).clamp(labBoardMin, labBoardMax);
  }

  @override
  Widget build(BuildContext context) {
    return _LabKeys(
      lab: lab,
      search: search,
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
                      TableBoards(lab: lab, boardSize: size, archive: archive),
                      const SizedBox(height: Space.s),
                      SizedBox(
                        width: size * 2 + labBoardGap,
                        child: ExpansionTile(
                          key: const ValueKey('bughouse-position-editor'),
                          title: const Text('Edit position / FEN'),
                          tilePadding: EdgeInsets.zero,
                          children: [BoardSetup(lab: lab, boardSize: size)],
                        ),
                      ),
                    ],
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
                      child: ListenableBuilder(
                        listenable: lab,
                        builder: (context, _) => lab.showMatches
                            ? MatchPanel(matches: matches, lab: lab)
                            : LabPanel(
                                lab: lab,
                                search: search,
                                archive: archive,
                              ),
                      ),
                    ),
                  ),
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
/// unless the user is typing, when the keys are the text box's. A setup box
/// clicked away from hands the focus back here (see `board_setup.dart`), so
/// the arrows step the boards again.
class _LabKeys extends StatefulWidget {
  const _LabKeys({
    required this.lab,
    required this.search,
    required this.windowKeys,
    required this.child,
  });

  final BughouseLab lab;
  final TableSearch search;
  final Map<ShortcutActivator, VoidCallback> windowKeys;
  final Widget child;

  @override
  State<_LabKeys> createState() => _LabKeysState();
}

class _LabKeysState extends State<_LabKeys> {
  final _focus = FocusNode(debugLabel: 'Bughouse lab');

  BughouseLab get lab => widget.lab;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Map<ShortcutActivator, VoidCallback> get _bindings => {
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () => lab.step(-1),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () => lab.step(1),
    const SingleActivator(LogicalKeyboardKey.home): lab.toStart,
    const SingleActivator(LogicalKeyboardKey.end): lab.toEnd,
    const SingleActivator(LogicalKeyboardKey.escape): () =>
        lab.preview.value = null,
    ...widget.windowKeys,
    const SingleActivator(LogicalKeyboardKey.keyE): widget.search.toggleEngine,
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
