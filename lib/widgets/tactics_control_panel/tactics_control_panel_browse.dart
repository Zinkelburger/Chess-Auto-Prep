// Browse-tab and database-management actions for the tactics control panel:
// play/return from browse, delete/batch-delete, clear database, and the edit
// dialogs. Split out of tactics_control_panel.dart (pure code motion).
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
    final count = sortedDescIndices.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Tactics'),
        content: Text(
          'Delete $count selected tactics?\n\nThis cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      for (final idx in sortedDescIndices) {
        await _database.deletePositionAt(idx);
      }
    }
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
      _syncPgnToCurrentTactic();
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Tactic'),
        content: Text(
          'Delete this tactic?\n\n'
          '${pos.mistakeType} ${pos.gameWhite} vs ${pos.gameBlack}\n'
          '${pos.positionContext}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      // Reactive: deletePositionAt notifies, which repaints via _onDbChanged.
      await _database.deletePositionAt(index);
    }
  }

  void _confirmClearDatabase() async {
    if (_blockStructuralEditOnExternalSet()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Database'),
        content: Text(
          'Delete all ${_database.positions.length} tactics positions, '
          'imported PGNs, and analyzed-games history?\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      // Wipe everything: positions, analyzed-games list, and stored PGNs
      await _database.clearPositions();
      await _database.clearAnalyzedGames();
      await StorageFactory.instance.saveImportedPgns('');
      _session.endSession();
      _resetBoardToStart();
    }
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
        _syncPgnToCurrentTactic();
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
    _showEditDialog(index);
  }
}
