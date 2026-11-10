import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../chess/bughouse/bpgn_moves.dart' show BpgnGames;
import '../features/bughouse/bughouse_screen.dart';
import '../storage/pgn_file_import.dart';
import '../storage/pgn_file_picker.dart';
import '../ui/app_action.dart';
import '../ui/app_keys.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_tabs.dart';
import 'mode.dart';
import 'mode_view.dart';
import 'window_input.dart';
import '../ui/app_icons.dart';

/// The Bughouse mode: its own screen, one board or two and what Hivemind
/// makes of them, with nothing of the workspace but the window around it.
/// The engine searches only while it is on screen.
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
        engine: _labs.engine,
        windowKeys: windowKeys,
      );

  @override
  Listenable get changes => Listenable.merge([_labs.lab, _labs.engine]);

  @override
  void entered() {
    // Stockfish would follow a board nobody sees, on the cores Hivemind is
    // using.
    workspace.analysis.pause(this, _pauseReason);
    _labs.engine.open();
  }

  @override
  void left() {
    _labs.engine.close();
    workspace.analysis.resume(this);
  }

  static const _pauseReason = 'Paused while Bughouse is open';

  @override
  List<AppAction> actions(ModeMenu menu) {
    final lab = _labs.lab;
    return [
      AppAction(
        _labs.engine.on ? 'Engine off' : 'Engine on',
        _labs.engine.toggle,
        group: 'Bughouse',
      ),
      AppAction(
        'Play best move',
        _labs.engine.rowsOn(lab.focus).isEmpty
            ? null
            : () => _labs.engine.playBest(lab.focus),
        group: 'Bughouse',
      ),
      AppAction('New game', lab.newGame, group: 'Bughouse'),
      AppAction(
        lab.single ? 'Flip board' : 'Flip boards',
        lab.flip,
        shortcut: AppKey.flipBoards.label,
        group: 'Bughouse',
      ),
      AppAction(
        'Copy dual FEN',
        () => unawaited(
          Clipboard.setData(ClipboardData(text: lab.position.lichessDualFen)),
        ),
        icon: AppIcons.copy,
        group: 'Position',
      ),
      AppAction(
        'Paste FEN or dual FEN',
        () => unawaited(_paste(lab.loadDualFen)),
        icon: AppIcons.paste,
        group: 'Position',
      ),
      AppAction(
        'Copy moves',
        lab.line.isEmpty
            ? null
            : () => unawaited(
                Clipboard.setData(ClipboardData(text: lab.movesText)),
              ),
        icon: AppIcons.copy,
        group: 'Position',
      ),
      AppAction(
        'Paste moves',
        () => unawaited(_paste(lab.pasteMoves)),
        icon: AppIcons.paste,
        group: 'Position',
      ),
      AppAction(
        'Open BPGN…',
        () => unawaited(_open()),
        icon: AppIcons.open,
        group: 'Position',
      ),
    ];
  }

  /// The desktop's file dialog, then the chosen file's moves on the boards,
  /// as Paste moves would put them. The file is read where it is and not
  /// kept; its games are found off the UI isolate. A file opened, or moves
  /// pasted, while an earlier file was still being read is what is shown.
  Future<void> _open() async {
    final path = await _labs.picker.pickPgn(extensions: bpgnExtensions);
    if (path == null) return;
    final opening = ++_opening;
    final name = p.basename(path);
    switch (await _labs.files.read(path)) {
      case PickedText(:final text):
        final games = await BpgnGames.index(text);
        if (_current(opening)) _labs.lab.openGames(games, file: name);
      case PickedUnread():
        if (_current(opening)) _labs.lab.fileUnread(name);
    }
  }

  /// Counts the files opened and the pastes, so only the latest is shown.
  int _opening = 0;

  bool _current(int opening) => opening == _opening && !_labs.disposed;

  Future<void> _paste(void Function(String text) into) async {
    final opening = ++_opening;
    final text = await _input.clipboard();
    if (!_current(opening) || text == null || text.trim().isEmpty) return;
    into(text);
  }
}
