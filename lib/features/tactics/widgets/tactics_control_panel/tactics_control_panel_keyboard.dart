// Keyboard-shortcut handling for the tactics control panel: the training
// navigation keys (solution toggle, prev/next/skip, auto-advance, engine
// toggle, PGN/board arrows, focus move input, tab switching), declared as
// [KeyBinding] lists.
//
// A `part`, not a collaborator: the whole file is one binding list whose
// every entry closes over this widget's tab controller, focus node, session
// and solution cursor. As an object it would take those as ten constructor
// callbacks and read as indirection, not structure.
part of '../tactics_control_panel.dart';

mixin _TacticsKeyboardActions
    on _TacticsControlPanelStateBase, _TacticsPlayback {
  /// Commands shared by panel controls and the screen's BoardKeyboardScope.
  List<KeyBinding> get _keyBindings => [
    ...KeyBinding.forShortcut(
      AppShortcut.toggleSolution,
      'Show/hide solution',
      _session.toggleSolution,
    ),
    // The puzzle queue is stepped by the same pair as every other list in the
    // app. Vertical arrows remain available with an always-hot move box because
    // they cannot appear in SAN or UCI. Mirror the button enablement: at the
    // ends of the queue the shortcuts do nothing, same as the grayed-out
    // Previous/Next buttons.
    ...KeyBinding.forShortcut(
      AppShortcut.previousItem,
      'Previous position',
      () {
        if (_session.hasPrevious) {
          _loadCurrentPosition(_session.previousPosition());
        }
      },
    ),
    ...KeyBinding.forShortcut(AppShortcut.nextItem, 'Skip/next position', () {
      if (_session.hasNext) {
        _loadCurrentPosition(_session.skipPosition());
      }
    }),
    ...KeyBinding.forShortcut(
      AppShortcut.autoAdvance,
      'Toggle auto-advance',
      () => _session.setAutoAdvance(!_session.autoAdvance),
    ),
    // ←/→ follow what is on screen. While you are solving there are no moves
    // to step through, so they fall through to switching puzzles. Once the
    // solution is on the board they walk it move by move, and on the PGN tab
    // they step the game (the app-wide ←/→ = moves convention). They are a
    // contextual convenience, not the advertised way to change puzzle — that
    // is ↑/↓, which works in every state.
    ...KeyBinding.forShortcut(
      AppShortcut.forwardOneMove,
      'Skip / forward one move',
      () {
        if (_tabController.index != 0) {
          _pgnViewerController.goForward();
        } else if (_session.showSolution) {
          if (_solutionNav.arrowForward()) setState(() {});
        } else if (_session.hasNext) {
          _loadCurrentPosition(_session.skipPosition());
        }
      },
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.backOneMove,
      'Previous / back one move',
      () {
        if (_tabController.index != 0) {
          _pgnViewerController.goBack();
        } else if (_session.showSolution) {
          if (_solutionNav.arrowBack()) setState(() {});
        } else if (_session.hasPrevious) {
          _loadCurrentPosition(_session.previousPosition());
        }
      },
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.analyzePosition,
      'Analyze (open PGN)',
      _onAnalyze,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.toggleEngine,
      'Toggle engine',
      () => InlineEngineBar.toggleEngine(context),
    ),
    ...KeyBinding.forShortcut(AppShortcut.flipBoard, 'Flip board', () {
      final appState = context.read<AppState>();
      appState.setBoardFlipped(!appState.boardFlipped);
    }),
    ...KeyBinding.forShortcut(
      AppShortcut.focusMoveInput,
      'Focus move input',
      () => TacticsControlPanel.moveInputKey.currentState?.focus(),
    ),
    ...KeyBinding.forShortcut(AppShortcut.nextTab, 'Switch Tactic/PGN tab', () {
      _tabController.animateTo(_tabController.index == 0 ? 1 : 0);
    }),
    // Same app-wide contract as the PGN viewer's Escape: leave whatever you are
    // in, innermost first. Here that is the PGN/Browse tab, then the puzzle
    // itself — which is what the app-bar back arrow does, so the key and the
    // button can never disagree about what "back" means.
    ...KeyBinding.forShortcutIf(
      AppShortcut.leave,
      'Back to Tactic tab / leave puzzle',
      () {
        if (_tabController.index != 0) {
          _tabController.animateTo(0);
          return true;
        }
        if (!_session.hasActivePosition) return false;
        _onBackRequested();
        return true;
      },
    ),
  ];
}
