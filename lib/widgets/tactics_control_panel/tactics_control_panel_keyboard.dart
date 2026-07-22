// Keyboard-shortcut handling for the tactics control panel: the training
// navigation keys (solution toggle, prev/next/skip, auto-advance, engine
// toggle, PGN/board arrows, focus move input, tab switching), declared as
// [KeyBinding] lists. Split out of tactics_control_panel.dart.
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

  /// All trainer shortcuts. While a move is being typed, only bindings whose
  /// key can never appear in move text fire ([KeyBinding.safeWhileTypingMoves]
  /// filters in [_dispatchTrainerKey]) — that's what lets Space/S/P/J work
  /// mid-type while N/A/E still type as move characters. ←/→ also navigate,
  /// but only reach here when the move field is empty: with text in it the
  /// field keeps ←/→ for caret editing (see [MoveInputWidget]) and never
  /// forwards them.
  List<KeyBinding> get _keyBindings => [
    KeyBinding.run(
      LogicalKeyboardKey.space,
      'Show/hide solution',
      _session.toggleSolution,
    ),
    // Mirror the button enablement: at the ends of the queue the shortcuts do
    // nothing, same as the grayed-out Previous/Next.
    for (final key in [LogicalKeyboardKey.keyP, LogicalKeyboardKey.arrowUp])
      KeyBinding.run(key, 'Previous position', () {
        if (_session.hasPrevious) {
          _loadCurrentPosition(_session.previousPosition());
        }
      }),
    for (final key in [LogicalKeyboardKey.keyS, LogicalKeyboardKey.arrowDown])
      KeyBinding.run(key, 'Skip/next position', () {
        if (_session.hasNext) {
          _loadCurrentPosition(_session.skipPosition());
        }
      }),
    KeyBinding.run(
      LogicalKeyboardKey.keyJ,
      'Toggle auto-advance',
      () => _session.setAutoAdvance(!_session.autoAdvance),
    ),
    // ←/→ walk the solution line (Tactic tab) or the PGN (Analysis tab).
    KeyBinding.run(LogicalKeyboardKey.arrowRight, 'Forward one move', () {
      if (_tabController.index == 0 && _session.showSolution) {
        if (_solutionNav.arrowForward()) setState(() {});
      } else {
        _pgnViewerController.goForward();
      }
    }),
    KeyBinding.run(LogicalKeyboardKey.arrowLeft, 'Back one move', () {
      if (_tabController.index == 0 && _session.showSolution) {
        if (_solutionNav.arrowBack()) setState(() {});
      } else {
        _pgnViewerController.goBack();
      }
    }),
    KeyBinding.run(LogicalKeyboardKey.keyN, 'Skip/next position', () {
      if (_session.hasNext) {
        _loadCurrentPosition(_session.skipPosition());
      }
    }),
    // 'A' is the mnemonic but it's the a-file, so it's swallowed as a typed
    // move character while the move box has focus (its default state). 'V' is
    // never part of SAN/UCI, so it stays [KeyBinding.safeWhileTypingMoves] and
    // triggers Analyze even mid-type — the reliable key to reach for.
    for (final key in [LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyV])
      KeyBinding.run(key, 'Analyze / reset analysis', () {
        final appState = context.read<AppState>();
        final isAtStartingPosition =
            appState.currentPosition.fen == _session.currentPosition!.fen;
        if (isAtStartingPosition) {
          _onAnalyze();
        } else {
          _resetAnalysis();
        }
      }),
    KeyBinding.run(
      LogicalKeyboardKey.keyE,
      'Toggle engine',
      InlineEngineBar.toggleEngine,
    ),
    // Match the app-wide F = flip convention (study, PGN viewer, repertoire).
    // F is the f-file so it isn't safeWhileTypingMoves — like those screens it
    // fires only when the board/panel (not the move box) owns focus.
    KeyBinding.run(LogicalKeyboardKey.keyF, 'Flip board', () {
      final appState = context.read<AppState>();
      appState.setBoardFlipped(!appState.boardFlipped);
    }),
    for (final key in [LogicalKeyboardKey.slash, LogicalKeyboardKey.tab])
      KeyBinding.run(
        key,
        'Focus move input',
        () => TacticsControlPanel.moveInputKey.currentState?.focus(),
      ),
    KeyBinding(LogicalKeyboardKey.escape, 'Back to Tactic tab', () {
      if (_tabController.index == 0) return false;
      _tabController.animateTo(0);
      return true;
    }),
  ];

  /// Core trainer key dispatch, shared by the panel's own [Focus] handler and
  /// the move-input bridge. [typingMove] is true when the move-input field
  /// owns focus — then only [KeyBinding.safeWhileTypingMoves] bindings fire.
  ///
  /// Uses [runKeyBindings] (no text-input guard) because the bridge runs
  /// precisely while the move field has focus; the field forwards keys
  /// explicitly and swallows what this claims. The panel path re-adds the
  /// guard in [_handleKeyEvent].
  KeyEventResult _dispatchTrainerKey(
    LogicalKeyboardKey key, {
    required bool typingMove,
  }) {
    final bindings = typingMove
        ? [
            for (final binding in _keyBindings)
              if (binding.safeWhileTypingMoves) binding,
          ]
        : _keyBindings;
    return runKeyBindings(bindings, key);
  }
}
