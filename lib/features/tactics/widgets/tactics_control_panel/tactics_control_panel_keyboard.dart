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

    // Typing is always live while the puzzle wants a move: a move character
    // pressed while the *panel* owns focus (after a board click, a button
    // press, a tab switch back…) is routed into the move box as if the box
    // were focused, instead of dying here or firing a letter shortcut. The
    // user should never have to click the box before typing "Qxb5".
    if (_routeMoveCharacter(event)) return KeyEventResult.handled;

    return _dispatchTrainerKey(event.logicalKey, typingMove: false);
  }

  /// True when [event] is a chess-move character the move box should receive
  /// right now: Tactic tab up front, the puzzle still waiting for the user's
  /// move, and no Ctrl/Alt held. Shift is allowed — piece letters are typed
  /// as capitals. While a move is wanted, e and f are files first, which is
  /// why the E/F shortcuts only fire once the puzzle is solved or revealed.
  bool _routeMoveCharacter(KeyEvent event) {
    if (_tabController.index != 0) return false;
    if (_session.positionSolved ||
        _session.showSolution ||
        _session.waitingForOpponent) {
      return false;
    }
    if (isPrimaryModifierPressed || HardwareKeyboard.instance.isAltPressed) {
      return false;
    }
    if (!isChessMoveTextKey(event.logicalKey)) return false;
    final character = event.character;
    if (character == null || character.isEmpty) return false;
    final input = TacticsControlPanel.moveInputKey.currentState;
    if (input == null) return false;
    return input.typeCharacter(character);
  }

  /// Bridge for keys pressed while the move-input field owns focus. The field
  /// and this panel are siblings in the focus tree, so key events can't bubble
  /// between them; [MoveInputWidget] forwards keys here (via
  /// [TacticsPanelHooks.navigationKey]) and swallows whatever
  /// this claims. Returns true when the key drove navigation.
  bool _handleTrainerNavigationKey(LogicalKeyboardKey key) {
    if (_session.currentPosition == null) return false;
    return _dispatchTrainerKey(key, typingMove: true) == KeyEventResult.handled;
  }

  /// All trainer shortcuts. While a move is being typed, only bindings whose
  /// key can never appear in move text fire ([KeyBinding.safeWhileTypingMoves]
  /// filters in [_dispatchTrainerKey]) — that's what lets Space/arrows/J work
  /// mid-type while N/A/E still type as move characters. ←/→ also navigate,
  /// but only reach here when the move field is empty: with text in it the
  /// field keeps ←/→ for caret editing (see [MoveInputWidget]) and never
  /// forwards them.
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
    // Analyze is V alone. 'A' was once its alias, but a is the a-file and the
    // move box is now always hot while solving, so an A binding could never
    // fire — advertising two keys where one is dead is worse than one key.
    // 'V' never appears in SAN/UCI, so it works even mid-type.
    ...KeyBinding.forShortcut(
      AppShortcut.analyzePosition,
      'Analyze (open PGN)',
      _onAnalyze,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.toggleEngine,
      'Toggle engine',
      InlineEngineBar.toggleEngine,
    ),
    // Match the app-wide F = flip convention (study, PGN viewer, repertoire).
    // F is the f-file so it isn't safeWhileTypingMoves — like those screens it
    // fires only when the board/panel (not the move box) owns focus.
    ...KeyBinding.forShortcut(AppShortcut.flipBoard, 'Flip board', () {
      final appState = context.read<AppState>();
      appState.setBoardFlipped(!appState.boardFlipped);
    }),
    ...KeyBinding.forShortcut(
      AppShortcut.focusMoveInput,
      'Focus move input',
      () => TacticsControlPanel.moveInputKey.currentState?.focus(),
    ),
    // Tab flips between the two sides of the panel — the puzzle and its PGN.
    // (It used to focus the move box, but the box is always hot now; the
    // reachable-by-keyboard thing you actually switch to is the other tab.)
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
