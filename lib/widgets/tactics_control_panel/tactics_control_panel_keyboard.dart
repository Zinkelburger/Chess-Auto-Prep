// Keyboard-shortcut handling for the tactics control panel: the training
// navigation keys (solution toggle, prev/next/skip, auto-advance, PGN/board
// arrows, focus move input, tab switching). Split out of
// tactics_control_panel.dart (pure code motion).
part of '../tactics_control_panel.dart';

mixin _TacticsKeyboardActions
    on _TacticsControlPanelStateBase, _TacticsPlayback {
  /// [Focus.onKeyEvent] for the panel itself — runs when the panel (not a text
  /// field) owns keyboard focus. Keys pressed while the move-input field is
  /// focused never reach here (the field is a focus-tree sibling); they arrive
  /// through [_handleTrainerNavigationKey] instead.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _session.currentPosition == null) {
      return KeyEventResult.ignored;
    }

    // Another text field in the panel subtree (import form, engine bar) owns
    // focus → let it type. The move input is handled separately, so it never
    // needs an exception here.
    if (isTextInputFocused()) {
      return KeyEventResult.ignored;
    }

    return _dispatchTrainerKey(event.logicalKey, typingMove: false);
  }

  /// Bridge for keys pressed while the move-input field owns focus. The field
  /// and this panel are siblings in the focus tree, so key events can't bubble
  /// between them; [MoveInputWidget] forwards keys here (via
  /// [TacticsSessionController.onTrainerNavigationKey]) and swallows whatever
  /// this claims. Returns true when the key drove navigation.
  bool _handleTrainerNavigationKey(LogicalKeyboardKey key) {
    if (_session.currentPosition == null) return false;
    return _dispatchTrainerKey(key, typingMove: true) == KeyEventResult.handled;
  }

  /// Core trainer key dispatch, shared by the panel's own [Focus] handler and
  /// the move-input bridge.
  ///
  /// [typingMove] is true when the move-input field owns focus. Keys that can
  /// never be part of a move (Space, S/P, J, ↑/↓) navigate in either case —
  /// that's what lets S/P switch puzzles even mid-type. ←/→ also navigate, but
  /// only reach here when the move field is empty: with text in it the field
  /// keeps ←/→ for caret editing (see [MoveInputWidget]) and never forwards
  /// them. Keys that overlap the move alphabet (N, A) or (re)focus the field
  /// (/, Tab, Escape) only fire when a move is *not* being typed.
  KeyEventResult _dispatchTrainerKey(
    LogicalKeyboardKey key, {
    required bool typingMove,
  }) {
    // ── Always-on keys (never part of a move) ──────────────────────────────
    if (key == LogicalKeyboardKey.space) {
      _session.toggleSolution();
      return KeyEventResult.handled;
    }

    // Mirror the button enablement: at the ends of the queue the shortcuts do
    // nothing, same as the grayed-out Previous/Next.
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

    // ←/→ walk the solution line (Tactic tab) or the PGN (Analysis tab).
    // While a move is being typed they're kept by the field for caret editing
    // (they only reach here when the move input is empty).
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

    // ── Keys below overlap move letters (n/a) or (re)focus the field ────────
    // They must not fire while a move is being typed.
    if (typingMove) {
      return KeyEventResult.ignored;
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
