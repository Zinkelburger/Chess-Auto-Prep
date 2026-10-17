import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../features/bughouse/bughouse_screen.dart';
import '../ui/app_action.dart';
import '../ui/app_keys.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_tabs.dart';
import 'mode.dart';
import 'mode_view.dart';
import 'window_input.dart';

/// The Bughouse lab: its own screen, two boards and what Hivemind makes
/// of them, with nothing of the workspace but the window around it. The
/// engine searches only while it is on screen.
final class BughouseView extends ModeView {
  BughouseView(Workspace workspace, this._labs, this._input)
    : super(workspace, readingTabs());

  final LabModes _labs;
  final WindowInput _input;

  @override
  Widget list(Widget toggle) => const SizedBox.shrink();

  @override
  Widget screen(Map<ShortcutActivator, VoidCallback> windowKeys) =>
      BughouseScreen(
        lab: _labs.lab,
        search: _labs.search,
        archive: _labs.archive,
        matches: _labs.matches,
        expectimax: _labs.expectimax,
        windowKeys: windowKeys,
      );

  @override
  Listenable get changes =>
      Listenable.merge([_labs.lab, _labs.search, _labs.matches]);

  @override
  void entered() {
    // Stockfish would follow a board nobody sees, on the cores Hivemind is
    // using.
    workspace.analysis.pause(this, _pauseReason);
    _labs.search.open();
    unawaited(_labs.archive.open());
    unawaited(_labs.matches.load());
  }

  @override
  void left() {
    _labs.expectimax.stop();
    _labs.search.close();
    workspace.analysis.resume(this);
  }

  static const _pauseReason = 'Paused while the Bughouse lab is open';

  @override
  List<AppAction> actions(ModeMenu menu) {
    final lab = _labs.lab;
    final search = _labs.search;
    return [
      AppAction(
        'Toggle engine',
        search.toggleEngine,
        shortcut: AppKey.engine.label,
        group: 'Bughouse',
      ),
      AppAction('New game', lab.newGame, group: 'Bughouse'),
      AppAction('Flip boards', lab.flip, group: 'Bughouse'),
      AppAction(
        lab.showMatches ? 'Back to analysis' : 'Matches',
        lab.toggleMatches,
        group: 'Bughouse',
      ),
      AppAction(
        'Copy dual FEN',
        () => unawaited(
          Clipboard.setData(ClipboardData(text: lab.position.dualFen)),
        ),
        group: 'Position',
      ),
      AppAction(
        'Paste dual FEN',
        () => unawaited(_paste(lab.loadDualFen)),
        group: 'Position',
      ),
      AppAction(
        'Copy moves',
        lab.line.moves.isEmpty
            ? null
            : () => unawaited(
                Clipboard.setData(ClipboardData(text: lab.movesText)),
              ),
        group: 'Position',
      ),
      AppAction(
        'Paste moves',
        () => unawaited(_paste(lab.pasteMoves)),
        group: 'Position',
      ),
    ];
  }

  Future<void> _paste(void Function(String text) into) async {
    final text = await _input.clipboard();
    if (text != null && text.trim().isNotEmpty) into(text);
  }
}
