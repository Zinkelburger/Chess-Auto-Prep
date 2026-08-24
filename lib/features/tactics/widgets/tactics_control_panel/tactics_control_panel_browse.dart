// What the browse list asks the panel to do: play a row, train a selection,
// delete one/many/all, and the edit dialogs.
//
// A `part`, not a collaborator: every one of these is a confirm-then-mutate
// handler that needs this widget's `context`, `mounted` and `setState`, so
// pulling them into an object would mean handing that object the widget back
// through a fistful of callbacks. The extractable piece — writing to the
// board and the PGN tab — already left, as `TacticsBoardBridge`.
part of '../tactics_control_panel.dart';

mixin _TacticsBrowseActions on _TacticsControlPanelStateBase, _TacticsPlayback {
  /// External sets (studies under review) only persist *stats* back to
  /// their file — structural changes (delete/edit/clear) would silently
  /// revert on reload, so they are redirected to Study mode.
  bool _blockStructuralEditOnExternalSet() {
    if (!_database.isExternalSet) return false;
    showAppSnackBar(
      context,
      'This is a study under review — edit its content in Study mode.',
      isError: true,
    );
    return true;
  }

  Future<void> _batchDeleteTactics(List<int> sortedDescIndices) async {
    if (_blockStructuralEditOnExternalSet()) return;
    final confirmed = await confirmAction(
      context,
      title: 'Delete Tactics',
      message:
          'Delete ${sortedDescIndices.length} selected tactics?\n\n'
          'This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;
    // One notify + one file write for the whole batch.
    await _database.deletePositionsAt(sortedDescIndices);
  }

  /// "Train these" / "Train" on the browse bar: a real scored session over
  /// exactly [indices] (the filtered list, or the checked rows), in the order
  /// the list showed them — filter on Struggling, press Train, and you are
  /// drilling your struggling puzzles with a recap at the end.
  void _trainTactics(List<int> indices) {
    if (indices.isEmpty) return;
    final subset = [for (final i in indices) _database.positions[i]];
    final setup = _session.startRetrySession(subset);
    if (setup == null) return;
    _showRecap = false;
    _loadPositionSetup(setup);
  }

  /// Play button on a browse row: load the tactic unscored, with
  /// Previous/Next walking [visibleIndices] (the list as filtered/sorted at
  /// click time) and the back button returning to the list.
  void _playTacticFromBrowse(int index, List<int> visibleIndices) {
    final pos = _database.positions[index];
    try {
      final setup = _session.selectPosition(
        pos,
        browseQueue: [for (final i in visibleIndices) _database.positions[i]],
      );
      if (setup != null) _applyPositionSetup(setup);
      _resetToCurrentTactic();
      // Land on the Tactic tab so the loaded puzzle is front and center.
      _tabController.animateTo(0);
      _focusNode.requestFocus();
    } catch (e) {
      debugPrint('Load position failed: $e');
      if (mounted) {
        showAppSnackBar(context, AppMessages.loadPositionFailed, isError: true);
      }
    }
  }

  void _deleteTactic(int index) async {
    if (_blockStructuralEditOnExternalSet()) return;
    final pos = _database.positions[index];
    final confirmed = await confirmAction(
      context,
      title: 'Delete Tactic',
      message:
          'Delete this tactic?\n\n'
          '${pos.mistakeType} ${pos.gameWhite} vs ${pos.gameBlack}\n'
          '${pos.positionContext}',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;
    // Reactive: deletePositionAt notifies, which repaints via _onDbChanged.
    await _database.deletePositionAt(index);
  }

  void _confirmClearDatabase() async {
    if (_blockStructuralEditOnExternalSet()) return;
    // "Delete", never "clear": clearing sounds like resetting filters, and
    // this destroys every stored tactic. The danger colour lives here on the
    // confirm, not on the browse-bar button that opens it.
    final confirmed = await confirmAction(
      context,
      title: 'Delete all tactics?',
      message:
          'Delete all ${_database.positions.length} tactics positions, '
          'imported PGNs, and analyzed-games history?\n\n'
          'This cannot be undone.',
      confirmLabel: 'Delete all',
    );
    if (!confirmed || !mounted) return;
    // Wipe everything: positions, analyzed-games list, and stored PGNs
    await _database.clearPositions();
    await _database.clearAnalyzedGames();
    await StorageFactory.instance.saveImportedPgns('');
    _session.endSession();
    _resetBoardToStart();
  }

  Future<void> _showEditDialog(int index) async {
    if (_blockStructuralEditOnExternalSet()) return;
    final original = _database.positions[index];
    final updated = await TacticsEditDialog.show(
      context,
      position: original,
      index: index,
    );

    if (updated != null && mounted) {
      final wasCurrent = _session.currentPosition?.fen == original.fen;
      await _database.updatePositionAt(index, updated);
      if (wasCurrent && mounted) {
        // The tactic on the board was edited (possibly its FEN or solution):
        // reload it in place so the board and puzzle state reflect the new
        // data without changing how it was launched (session vs browse).
        final setup = _session.reloadCurrentPosition(updated);
        if (setup != null) _applyPositionSetup(setup);
        _resetToCurrentTactic();
      }
    }
  }

  /// Edit the tactic currently loaded on the board (from the training panel's
  /// edit button). Resolves the database index by FEN.
  void _editCurrentTactic() {
    final current = _session.currentPosition;
    if (current == null) return;
    final index = _database.positions.indexWhere((p) => p.fen == current.fen);
    if (index < 0) return;
    unawaited(_showEditDialog(index));
  }
}
