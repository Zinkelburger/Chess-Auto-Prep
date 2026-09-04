// Session lifecycle for the tactics control panel: loading a puzzle, walking
// off either end of the queue, the recap and retry, and the clipboard /
// add-to-study actions on the loaded tactic.
//
// The board and PGN writes these used to do by hand now belong to
// `TacticsBoardBridge`; what is left here is the widget-shaped half —
// tab switching, focus, snack bars and `setState`.
part of '../tactics_control_panel.dart';

mixin _TacticsPlayback on _TacticsControlPanelStateBase {
  void _applyBoardUpdate(TacticsBoardUpdate update) {
    if (mounted) _board.applyUpdate(update);
  }

  void _addMoveToAnalysis(String moveUci) {
    if (mounted) _board.playMove(moveUci);
  }

  void _applyPositionSetup(TacticsPositionSetup setup) {
    if (!mounted) return;
    final error = _board.showPosition(setup);
    if (error != null) setState(() => _session.feedback = error);
  }

  void _resetBoardToStart() => _board.resetToStart();

  void _resetToCurrentTactic() =>
      _board.resetToTactic(_session.currentPosition?.fen);

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
      buildPgn: (_) =>
          sourceGamePgn(tactic, _session.engine.solutionLineToSan(tactic)),
    );
  }

  /// "Copy game PGN" from the game menu.
  Future<void> _copyGamePgn() async {
    final tactic = _session.currentPosition;
    if (tactic == null) return;
    try {
      final pgn = await sourceGamePgn(
        tactic,
        _session.engine.solutionLineToSan(tactic),
      );
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
    return confirmAction(
      context,
      title: 'End session?',
      message: 'This ends the current training session.',
      confirmLabel: 'End session',
      destructive: false,
    );
  }
}
