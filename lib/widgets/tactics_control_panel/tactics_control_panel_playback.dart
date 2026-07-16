// Board/position playback, analysis, and session-lifecycle actions for the
// tactics control panel: applying board updates and position setups, PGN sync,
// analyze/reset, FEN copy, and start/exhaust/recap/retry of a session.
// Split out of tactics_control_panel.dart (pure code motion).
part of '../tactics_control_panel.dart';

mixin _TacticsPlayback on _TacticsControlPanelStateBase {
  void _applyBoardUpdate(TacticsBoardUpdate update) {
    if (!mounted) return;
    final appState = context.read<AppState>();
    try {
      if (update.applyMoveUci != null) {
        final move = Move.parse(update.applyMoveUci!);
        if (move != null) {
          appState.setCurrentPosition(appState.currentPosition.play(move));
          appState.notifyGameChanged();
        }
      } else if (update.setFen != null) {
        final position = Chess.fromSetup(Setup.parseFen(update.setFen!));
        appState.setCurrentPosition(position);
      }
      if (update.san != null) {
        _pgnViewerController.goForward();
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

  /// Re-sync the PGN viewer to the tactic start (solution mainline index 0).
  void _syncPgnToCurrentTactic() {
    _pgnViewerController.clearEphemeralMoves();
    _pgnViewerController.goToMainLineIndex(0);
  }

  void _resetAnalysis() {
    if (_session.currentPosition == null) return;

    _solutionNav.reset();
    final setup = _session.resetPuzzleState();
    if (setup != null) _applyPositionSetup(setup);
    _syncPgnToCurrentTactic();
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

  void _loadPositionSetup(TacticsPositionSetup setup) {
    _solutionNav.reset();
    _applyPositionSetup(setup);
    _syncPgnToCurrentTactic();
    TacticsControlPanel.moveInputKey.currentState?.focus();
  }

  /// Click handler for a move in the solution line: jump there and repaint.
  void _onSolutionLineMoveTapped(List<String> sanMoves, int clickedIndex) {
    _solutionNav.onMoveTapped(sanMoves, clickedIndex);
    setState(() {});
  }

  void _onAnalyze() {
    _tabController.animateTo(1);
    _focusNode.requestFocus();
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
