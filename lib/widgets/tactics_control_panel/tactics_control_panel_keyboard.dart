// Keyboard-shortcut handling for the tactics control panel: the training
// navigation keys (solution toggle, prev/next/skip, auto-advance, PGN/board
// arrows, focus move input, tab switching). Split out of
// tactics_control_panel.dart (pure code motion).
part of '../tactics_control_panel.dart';

mixin _TacticsKeyboardActions
    on _TacticsControlPanelStateBase, _TacticsPlayback {
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _session.currentPosition == null) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    // "Typing a move" is not "typing text": a move can only contain
    // a-h / 1-8 / K Q R B N / o-0 / x / '-', so keys outside that alphabet
    // (Space, ↑/↓, P, S, J) stay live while the move input is focused.
    // Any *other* focused text field (engine bar, import form) still
    // swallows everything.
    final typingMove =
        TacticsControlPanel.moveInputKey.currentState?.hasFocus ?? false;
    if (isTextInputFocused() && !typingMove) {
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.space) {
      _session.toggleSolution();
      return KeyEventResult.handled;
    }

    // Mirror the button enablement: at the ends of the queue the shortcuts
    // do nothing, same as the grayed-out Previous/Next.
    if ((key == LogicalKeyboardKey.keyP || key == LogicalKeyboardKey.arrowUp) &&
        hasNoLetterModifiers) {
      if (_session.hasPrevious) {
        _loadCurrentPosition(_session.previousPosition());
      }
      return KeyEventResult.handled;
    }

    if ((key == LogicalKeyboardKey.keyS ||
            key == LogicalKeyboardKey.arrowDown) &&
        hasNoLetterModifiers) {
      if (_session.hasNext) {
        _loadCurrentPosition(_session.skipPosition());
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyJ && hasNoLetterModifiers) {
      _session.setAutoAdvance(!_session.autoAdvance);
      return KeyEventResult.handled;
    }

    // Everything below overlaps with move letters (n/a/e) or caret editing
    // (←/→), so it only fires when the move input is not focused.
    if (typingMove) {
      return KeyEventResult.ignored;
    }

    // Left/Right arrow — navigate solution on Tactic tab, PGN on Analysis tab
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_tabController.index == 0 && _session.showSolution) {
        if (_solutionNav.arrowForward()) setState(() {});
      } else {
        _pgnViewerController.goForward();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_tabController.index == 0 && _session.showSolution) {
        if (_solutionNav.arrowBack()) setState(() {});
      } else {
        _pgnViewerController.goBack();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyN && hasNoLetterModifiers) {
      if (_session.hasNext) {
        _loadCurrentPosition(_session.skipPosition());
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyA && hasNoLetterModifiers) {
      final appState = context.read<AppState>();
      final isAtStartingPosition =
          appState.currentPosition.fen == _session.currentPosition!.fen;
      if (isAtStartingPosition) {
        _onAnalyze();
      } else {
        _resetAnalysis();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.slash && hasNoLetterModifiers) {
      TacticsControlPanel.moveInputKey.currentState?.focus();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.tab) {
      TacticsControlPanel.moveInputKey.currentState?.focus();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (_tabController.index != 0) {
        _tabController.animateTo(0);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }
}
