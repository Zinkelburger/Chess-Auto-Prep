import 'dart:async';

import 'package:flutter/gestures.dart'
    show kBackMouseButton, kForwardMouseButton;
import 'package:flutter/widgets.dart';

import '../features/tactics/puzzle_trainer.dart';
import '../ui/app_keys.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_tabs.dart';
import 'board_doors.dart';
import 'full_screen.dart';
import 'mode_view.dart';
import 'search_door.dart';
import 'window_actions.dart';
import 'window_columns.dart';
import 'workspace_requests.dart';

/// The window's own keys, over the workspace's, and the mouse's back and
/// forward buttons: what each does in the mode on screen.
final class WindowKeys {
  WindowKeys({
    required this.requests,
    required this.workspace,
    required this.puzzles,
    required this.columns,
    required this.doors,
    required this.search,
    required this.actions,
    required this.fullScreen,
    required this.view,
    required this.inspecting,
  });

  final WorkspaceRequests requests;
  final Workspace workspace;
  final PuzzleTrainer puzzles;
  final WindowColumns columns;
  final BoardDoors doors;
  final SearchDoor search;
  final WindowActions actions;

  /// Whether the window fills the screen: F11, Esc and the Actions menu.
  final FullScreen fullScreen;

  /// The mode on screen, and whether its Analysis tab inspects a board of
  /// its own.
  final ModeView Function() view;
  final bool Function() inspecting;

  /// Every key the window adds to the workspace's.
  Map<ShortcutActivator, VoidCallback> all(BuildContext context) => {
    // ← takes back a move made past the file on the explorer Book's free board
    // before it steps back in the file.
    if (!inspecting()) ...AppKey.back.bind(workspace.tree.back),
    ...screen(context),
    ...AppKey.toggleList.bind(columns.toggleList),
    ...AppKey.positions.bind(columns.togglePositions),
    ...AppKey.openFile.bind(() => unawaited(requests.openPgnFile())),
    ...AppKey.paste.bind(() => unawaited(doors.paste())),
    ...AppKey.pastePosition.bind(
      () => unawaited(doors.paste(positionOnly: true)),
    ),
    ...AppKey.setUpPosition.bind(() => unawaited(doors.setUp(context))),
    ...AppKey.analysisBoard.bind(() => unawaited(actions.analyze())),
    ...AppKey.search.bind(() => unawaited(search.search(view().layout))),
    ...AppKey.play.bind(_space),
    ...AppKey.nextGame.bind(() => _walk(1)),
    ...AppKey.previousGame.bind(() => _walk(-1)),
  };

  /// The window's keys a mode with a screen of its own keeps: the settings,
  /// the actions typed for, full screen, and Alt+← and Alt+→ back to where
  /// the last jump came from and forward again. The rest are the
  /// workspace's, but for the paste ([BoardDoors.onScreen]).
  Map<ShortcutActivator, VoidCallback> screen(BuildContext context) => {
    ...AppKey.fullScreen.bind(fullScreen.toggle),
    ...AppKey.settings.bind(() => unawaited(actions.settings(context))),
    ...AppKey.actions.bind(() => unawaited(actions.palette(context))),
    ...AppKey.historyBack.bind(back),
    ...AppKey.historyForward.bind(forward),
  };

  void back() => unawaited(requests.back());
  void forward() => unawaited(requests.forward());

  /// The mouse's own back and forward buttons do what Alt+← and Alt+→ do.
  void mouseButton(PointerDownEvent event) {
    if (event.buttons & kBackMouseButton != 0) back();
    if (event.buttons & kForwardMouseButton != 0) forward();
  }

  /// What Esc leaves once the workspace has nothing left: the mode's
  /// sitting, then full screen.
  bool leave() => view().leave() || fullScreen.leave();

  /// Space shows the answer while a puzzle is on the board; otherwise it
  /// is the mode's: the viewer's autoplay.
  void _space() {
    if (inspecting()) return;
    if (puzzles.up == null) return view().space();
    puzzles.showSolution();
  }

  /// ↓ (1) / ↑ (−1) walk what is in front of the user: the Positions when
  /// they are, the mode's own list when it has one (My games), the puzzles
  /// in a sitting, else the file's games.
  void _walk(int by) {
    if (inspecting()) view().tabs.show(WorkspaceTab.moves);
    if (columns.walksPositions) {
      if (workspace.finds.step(by) case final next?) doors.openFind(next);
      return;
    }
    if (view().walk(by)) return;
    if (puzzles.up != null) {
      unawaited(by > 0 ? puzzles.next() : puzzles.previous());
    } else {
      by > 0 ? workspace.session.nextGame() : workspace.session.previousGame();
    }
  }
}
