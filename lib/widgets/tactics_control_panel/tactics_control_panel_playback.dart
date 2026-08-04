// Board/position playback, analysis, and session-lifecycle actions for the
// tactics control panel: applying board updates and position setups, PGN sync,
// analyze/reset, FEN copy, and start/exhaust/recap/retry of a session.
// Split out of tactics_control_panel.dart (pure code motion).
part of '../tactics_control_panel.dart';

mixin _TacticsPlayback on _TacticsControlPanelStateBase {
  /// Apply a move (or position) the session produced to the board, and record
  /// it in the PGN tab.
  ///
  /// Everything played at the board lands in the PGN tree — the solution moves
  /// you found, the wrong ones you tried, and the opponent's replies — as a
  /// variation off the position you played it from. Switching to the PGN tab
  /// then shows the line you just played instead of an untouched game you have
  /// to re-enter by hand.
  ///
  /// This replaced a `goForward()` on the PGN cursor, which assumed the
  /// solution *was* the PGN mainline. That stopped being true once puzzles
  /// started carrying their whole source game: the mainline there is the game
  /// as played, so stepping it forward walked onto the move the player
  /// actually blundered, not the one they had just found.
  void _applyBoardUpdate(TacticsBoardUpdate update) {
    if (!mounted) return;
    final appState = context.read<AppState>();
    try {
      if (update.applyMoveUci != null) {
        final move = Move.parse(update.applyMoveUci!);
        if (move != null) {
          final (newPos, san) = appState.currentPosition.makeSan(move);
          appState.setCurrentPosition(newPos);
          appState.notifyGameChanged();
          _pgnViewerController.addEphemeralMove(san);
        }
      } else if (update.setFen != null) {
        final position = Chess.fromSetup(Setup.parseFen(update.setFen!));
        appState.setCurrentPosition(position);
        // The opponent's reply arrives as a FEN plus its SAN.
        if (update.san != null) {
          _pgnViewerController.addEphemeralMove(update.san!);
        }
      }
    } catch (e) {
      debugPrint('[TacticsPanel] Board update failed: $e');
    }
  }

  void _applyPositionSetup(TacticsPositionSetup setup) {
    if (!mounted) return;
    final appState = context.read<AppState>();
    try {
      final position = Chess.fromSetup(Setup.parseFen(setup.fen));
      appState.setCurrentPosition(position);
      appState.setBoardFlipped(setup.flipBoard);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _session.feedback = 'Error loading position: $e';
      });
    }
  }

  /// Reset the board to the standard starting position (used when returning
  /// to the import screen so a stale tactic FEN isn't left on the board).
  void _resetBoardToStart() {
    final appState = context.read<AppState>();
    appState.setCurrentPosition(Chess.initial);
    appState.setBoardFlipped(false);
  }

  /// The tactic on the board changed (loaded, reloaded after an edit, or
  /// reset): drop the solution-line cursor and the scratch analysis, and park
  /// the PGN viewer back on the tactic's own position.
  ///
  /// That position is a ply *inside* the source game, not its first move —
  /// this used to jump to mainline index 0, which is where the game starts,
  /// left over from when a tactic's PGN was its solution and nothing else.
  /// Falls back to the game start only when the tactic's position isn't in
  /// the loaded game (a viewer that hasn't mounted yet, or still holds the
  /// previous tactic).
  void _resetToCurrentTactic() {
    _solutionNav.reset();
    _pgnViewerController.clearEphemeralMoves();
    final fen = _session.currentPosition?.fen;
    if (fen == null || !_pgnViewerController.goToFen(fen)) {
      _pgnViewerController.goToMainLineIndex(0);
    }
  }

  void _resetAnalysis() {
    if (_session.currentPosition == null) return;

    final setup = _session.resetPuzzleState();
    if (setup != null) _applyPositionSetup(setup);
    _resetToCurrentTactic();
  }

  void _onStartSession(TacticsSessionSettings settings) {
    final setup = _session.startSession(settings);
    if (setup == null) return;
    _showRecap = false;
    _loadPositionSetup(setup);
  }

  void _loadCurrentPosition(TacticsPositionSetup? setup) {
    if (setup == null) {
      _onQueueExhausted();
      return;
    }
    _loadPositionSetup(setup);
  }

  /// Previous/Next/auto-advance walked off the end of the queue: a session
  /// gets its recap, a browse walk just returns to the list.
  void _onQueueExhausted() {
    if (_session.playSource == TacticsPlaySource.browse) {
      _returnToBrowse();
    } else {
      _showSessionRecap();
    }
  }

  /// The app-bar back arrow (next to the "Tactics" title): leaves the
  /// current puzzle — back to the browse list for browse-launched play,
  /// otherwise ends the session (no recap) and lands on the home panel.
  void _onBackRequested() {
    if (_session.playSource == TacticsPlaySource.browse) {
      _returnToBrowse();
    } else {
      _leaveSession();
    }
  }

  /// Leave a browse-launched puzzle and land back on the browse list
  /// (the back button, or walking off either end of the browse queue).
  void _returnToBrowse() {
    _session.endSession();
    _showRecap = false;
    _resetBoardToStart();
    setState(() {});
    // With nothing loaded the second tab is Browse again.
    _tabController.animateTo(1);
  }

  /// The app-bar back arrow during a session: abandon the queue (no recap)
  /// and land back on the home/import panel.
  void _leaveSession() {
    _session.endSession();
    _showRecap = false;
    _resetBoardToStart();
    setState(() {});
  }

  void _loadPositionSetup(TacticsPositionSetup setup) {
    _applyPositionSetup(setup);
    _resetToCurrentTactic();
    // A new puzzle always lands on the Tactic tab, whatever tab the last one
    // was left on — reopening a puzzle onto its predecessor's PGN read as
    // opening the wrong screen. (Browse-launched play does the same in
    // _playTacticFromBrowse.)
    _tabController.animateTo(0);
    // The move field only exists while a puzzle is loaded (the pre-training
    // board has none), so on the first puzzle of a session it mounts in the
    // frame this call schedules — focus it once that frame has built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      TacticsControlPanel.moveInputKey.currentState?.focus();
    });
  }

  /// Click handler for a move in the solution line: jump there and repaint.
  /// The rendered SANs come from the navigator's own cache, so the list the
  /// widget hands back is redundant here.
  void _onSolutionLineMoveTapped(List<String> _, int clickedIndex) {
    _solutionNav.onMoveTapped(clickedIndex);
    setState(() {});
  }

  void _onAnalyze() {
    _tabController.animateTo(1);
    _focusNode.requestFocus();
  }

  /// The tactic's full source game PGN (looked up by id in the stored-PGN
  /// archive), falling back to the solution-only PGN when it isn't stored.
  Future<String> _currentGamePgn(TacticsPosition tactic) async {
    if (tactic.gameId.isNotEmpty) {
      final stored = await findStoredGamePgn(tactic.gameId);
      if (stored.isNotEmpty) return stored;
    }
    return buildSolutionPgn(tactic, _session.engine.correctLineToSan(tactic));
  }

  /// "Add game to study…" from the game menu: append the tactic's source
  /// game as a chapter of a study (same picker as every other add-to-study).
  Future<void> _addGameToStudy() async {
    final tactic = _session.currentPosition;
    if (tactic == null) return;
    final suggested = tactic.gameWhite.isEmpty && tactic.gameBlack.isEmpty
        ? 'Tactic game'
        : '${tactic.gameWhite} vs ${tactic.gameBlack}';
    await runAddToStudyFlow(
      context,
      suggestedChapterName: suggested,
      pickerTitle: 'Add game to study',
      viewActionLabel: 'View game',
      buildPgn: (_) => _currentGamePgn(tactic),
    );
  }

  /// "Copy game PGN" from the game menu.
  Future<void> _copyGamePgn() async {
    final tactic = _session.currentPosition;
    if (tactic == null) return;
    try {
      final pgn = await _currentGamePgn(tactic);
      await Clipboard.setData(ClipboardData(text: pgn));
      if (mounted) showAppSnackBar(context, 'Game PGN copied.');
    } catch (e) {
      debugPrint('Copy game PGN failed: $e');
      if (mounted) {
        showAppSnackBar(
          context,
          AppMessages.clipboardWriteFailed,
          isError: true,
        );
      }
    }
  }

  Future<void> _copyFen() async {
    if (_session.currentPosition != null) {
      try {
        await Clipboard.setData(
          ClipboardData(text: _session.currentPosition!.fen),
        );
        if (mounted) {
          showAppSnackBar(context, AppMessages.fenCopied);
        }
      } catch (e) {
        debugPrint('Copy FEN failed: $e');
        if (mounted) {
          showAppSnackBar(
            context,
            AppMessages.clipboardWriteFailed,
            isError: true,
          );
        }
      }
    }
  }

  void _addMoveToAnalysis(String moveUci) {
    final appState = context.read<AppState>();
    final position = appState.currentPosition;

    try {
      final move = Move.parse(moveUci);
      if (move == null) return;

      final (newPos, san) = position.makeSan(move);
      appState.setCurrentPosition(newPos);
      appState.notifyGameChanged();
      _pgnViewerController.addEphemeralMove(san);
    } catch (_) {
      // Best-effort; failure here is non-fatal and intentionally ignored.
    }
  }

  /// The session queue is exhausted: end it and show the recap card.
  /// (Falls back to the plain home panel when there's nothing to recap,
  /// e.g. navigating off a browse-selected position with no session.)
  void _showSessionRecap() {
    final hadSession = _session.sessionOutcomes.isNotEmpty;
    _session.endSession();
    _resetBoardToStart();
    setState(() => _showRecap = hadSession);
  }

  /// "Retry mistakes" on the recap: new session over the failed/skipped
  /// puzzles, in the order they were shown.
  void _retryMistakes() {
    final setup = _session.startRetrySession(_session.sessionMistakes);
    if (setup == null) return;
    setState(() => _showRecap = false);
    _loadPositionSetup(setup);
  }

  /// Leave the study review and return to the tactics database.
  Future<void> _exitExternalReview() async {
    if (!await _confirmEndSession()) return;
    _session.endSession();
    _showRecap = false;
    await _database.closeExternalSet();
    if (mounted) _resetBoardToStart();
  }

  /// Confirm ending an in-progress puzzle before an action that discards the
  /// session queue.  Returns true when it is safe to proceed.
  Future<bool> _confirmEndSession() async {
    if (!_session.hasActivePosition) return true;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End session?'),
        content: const Text('This ends the current training session.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End session'),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }
}
