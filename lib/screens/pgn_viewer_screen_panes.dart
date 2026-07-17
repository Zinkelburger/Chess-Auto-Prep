// Body builders for the PGN viewer: full-screen view, board pane, tabbed
// side panel, game tab (engine bar + movetext + nav bar, plus the empty
// states), and the amend-mode bar. Part of pgn_viewer_screen.dart.
part of 'pgn_viewer_screen.dart';

/// Board-pane / side-panel / game-tab builders, split out of
/// [_PgnViewerScreenState].
mixin _PaneBuildersMixin on State<PgnViewerScreen> {
  PgnViewerController get _controller;
  PgnViewerWidgetController get _pgnWidgetController;
  GameAnalysisController get _analysisController;
  TabController get _tabController;
  bool get _editMode;
  void _toggleEditMode();
  Future<void> _pickFile();
  Future<void> _loadFile(String path);
  Future<void> _copyCurrentGamePgn();
  void _reclaimFocus();

  Widget _buildFullScreenView(ThemeData theme) {
    return FullscreenGameView(
      position: _controller.currentPosition,
      boardFlipped: _controller.boardFlipped,
      gameLabel: _controller.filteredGames.isNotEmpty
          ? _controller.filteredGames[_controller.currentGameIndex].label
          : '',
      currentIndex: _controller.currentGameIndex,
      totalGames: _controller.filteredGames.length,
      isAutoPlaying: _controller.isAutoPlaying,
      autoPlayDelaySec: _controller.autoPlayDelaySec,
      autoNextGame: _controller.autoNextGame,
      onBoardMove: (san) {
        _controller.stopAutoPlay();
        _pgnWidgetController.addEphemeralMove(san);
      },
      onPrev: _controller.prevGame,
      onNext: _controller.nextGame,
      onGoBack: () {
        _controller.stopAutoPlay();
        _pgnWidgetController.goBack();
      },
      onGoForward: () {
        _controller.stopAutoPlay();
        _pgnWidgetController.goForward();
      },
      onToggleAutoPlay: _controller.toggleAutoPlay,
      onExit: _controller.exitFullScreen,
      onSetSpeed: _controller.setAutoPlaySpeed,
      onSetAutoNext: _controller.setAutoNextGame,
    );
  }

  Widget _buildBoardPane() {
    final solitaire = _controller.solitaire;
    final showFeedback =
        _controller.isSolitaireMode && solitaire.feedback != null;

    return Container(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            children: [
              ChessBoardWidget(
                position: _controller.currentPosition,
                flipped: _controller.boardFlipped,
                onMove: (move) => _controller.onBoardMove(move.san),
                // In solitaire, moves are allowed while guessing and again
                // once the game completes (free exploration of the annotated
                // game); only opponent auto-play locks the board.
                enableUserMoves:
                    !_controller.isSolitaireMode ||
                    solitaire.waitingForUser ||
                    solitaire.isComplete,
              ),
              // Only wrong guesses get an overlay; a correct guess just plays
              // out on the board (the green popup was noise).
              if (showFeedback &&
                  solitaire.feedback == SolitaireFeedback.incorrect)
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.dangerSurface.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Incorrect — try again',
                        style: TextStyle(
                          color: AppColors.ink,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSidePanel() {
    if (_controller.showOpeningTree) {
      return PgnOpeningTreePanel(controller: _controller);
    }
    // Solitaire is a pure guessing exercise: no Analysis tab (and no engine).
    final showTabs = !_controller.isSolitaireMode;
    return Column(
      children: [
        if (showTabs)
          Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  tabs: [
                    const Tab(text: 'Game'),
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Analysis'),
                          if (_analysisController.isAnalyzing) ...[
                            const SizedBox(width: 6),
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        Expanded(
          child: showTabs
              ? TabBarView(
                  controller: _tabController,
                  children: [
                    _buildGameTab(),
                    GameAnalysisTab(
                      analysisController: _analysisController,
                      pgnController: _pgnWidgetController,
                      currentPly: _controller.currentPly,
                      variationDepth: _pgnWidgetController.variationDepth,
                      gamePgnText: _controller.filteredGames.isNotEmpty
                          ? _controller
                                .filteredGames[_controller.currentGameIndex]
                                .pgnText
                          : null,
                      onAnnotatedMovetext: _controller.persistMoveComments,
                      onUserNavigation: () {
                        _controller.stopAutoPlay();
                        _reclaimFocus();
                      },
                    ),
                  ],
                )
              : _buildGameTab(),
        ),
        if (_controller.filteredGames.isNotEmpty)
          GameNavBar(
            games: _controller.filteredGames
                .map(
                  (g) => GameNavItem(
                    label: g.label,
                    studyRating: g.studyRating,
                    studySummary: g.studySummary,
                    headers: g.headers,
                  ),
                )
                .toList(),
            currentIndex: _controller.currentGameIndex,
            currentRating: _controller
                .filteredGames[_controller.currentGameIndex]
                .studyRating,
            sortMode: _controller.sortMode,
            isAutoPlaying: _controller.isAutoPlaying,
            autoPlayDelaySec: _controller.autoPlayDelaySec,
            autoNextGame: _controller.autoNextGame,
            onPrev: _controller.prevGame,
            onNext: _controller.nextGame,
            onGoToGame: _controller.goToGame,
            onSetRating: _controller.setRating,
            onSetSortMode: _controller.setSortMode,
            onToggleAutoPlay: _controller.toggleAutoPlay,
            onToggleFullScreen: _controller.toggleFullScreen,
            onSetSpeed: _controller.setAutoPlaySpeed,
            onSetAutoNext: _controller.setAutoNextGame,
            onCopyPgn: _copyCurrentGamePgn,
            hasEphemeralAnnotations: _pgnWidgetController.hasEphemeralMoves,
            onClearAnnotations: () {
              _controller.stopAutoPlay();
              _pgnWidgetController.clearEphemeralMoves();
              setState(() {});
              _reclaimFocus();
            },
            onToggleEditMode: _toggleEditMode,
            isEditMode: _editMode,
            isSolitaireMode: _controller.isSolitaireMode,
            solitaireWaitingForUser:
                _controller.isSolitaireMode &&
                _controller.solitaire.waitingForUser,
            solitaireCanReveal:
                _controller.isSolitaireMode && _controller.solitaire.canReveal,
            solitaireRevealCountdown: _controller.isSolitaireMode
                ? _controller.solitaire.revealCountdownSec
                : 0,
            onReveal: _controller.revealCurrentMove,
            onExitSolitaire: _controller.toggleSolitaire,
          ),
      ],
    );
  }

  Widget _buildGameTab() {
    if (_controller.filteredGames.isEmpty &&
        _controller.allGames.isNotEmpty &&
        _controller.hasActiveFilters) {
      // A file is loaded but the active slice matches nothing — without an
      // escape hatch here the chip bar is gone and the filter is unremovable.
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.filter_alt_off,
              size: 48,
              color: AppColors.onSurfaceDim,
            ),
            const SizedBox(height: 16),
            const Text(
              'No games match the current filters',
              style: AppTextStyles.emptyStateTitle,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _controller.resetFilters,
              icon: const Icon(Icons.filter_alt_off),
              label: const Text('Show All Games'),
            ),
          ],
        ),
      );
    }
    if (_controller.filteredGames.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.menu_book,
                size: 48,
                color: AppColors.onSurfaceDim,
              ),
              const SizedBox(height: 16),
              const Text('No PGN loaded', style: AppTextStyles.emptyStateTitle),
              if (_controller.errorMessage != null) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _controller.errorMessage!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _pickFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Open PGN File'),
              ),
              if (_controller.recentFiles.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Recent',
                  style: AppTextStyles.caption.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                for (final path in _controller.recentFiles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: InkWell(
                      onTap: () => _loadFile(path),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppColors.divider),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.description,
                              size: 16,
                              color: AppColors.onSurfaceMuted,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                p.basename(path),
                                style: AppTextStyles.muted.copyWith(
                                  color: AppColors.info,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    }
    final game = _controller.filteredGames[_controller.currentGameIndex];
    return Column(
      children: [
        if (!_controller.isSolitaireMode)
          InlineEngineBar(
            fen: _controller.currentPosition.fen,
            onLineMoveTapped: _controller.onEngineLineMoveTapped,
          ),
        if (_controller.isSolitaireMode)
          SolitaireStatusBar(
            controller: _controller,
            onReclaimFocus: _reclaimFocus,
          ),
        if (_controller.isSolitaireMode && _controller.solitaire.isComplete)
          SolitaireCompleteBanner(controller: _controller),
        const Divider(height: 1),
        if (_editMode) _buildEditModeBar(),
        Expanded(
          child: PgnViewerWidget(
            key: ValueKey('game_${_controller.currentGameIndex}'),
            pgnText: game.pgnText,
            controller: _pgnWidgetController,
            onPositionChanged: _controller.onPositionChanged,
            // Bound to this game object: the annotation panel debounces its
            // saves, which may flush after the user switches games.
            onCommentsChanged: (movetext) =>
                _controller.persistMoveCommentsFor(game, movetext),
            editMode: _editMode,
            revealedPly: _controller.isSolitaireMode
                ? _controller.solitaire.revealedPly
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildEditModeBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        border: Border(
          bottom: BorderSide(
            color: AppColors.warning.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.edit, size: 14, color: AppColors.warning),
          const SizedBox(width: 6),
          const Text(
            'Amending',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.warning,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Moves you play are saved to the file · '
              'click any move, then comment or glyph it below',
              style: AppTextStyles.caption.copyWith(fontSize: 11),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _toggleEditMode,
            icon: const Icon(
              Icons.close,
              size: 14,
              color: AppColors.onSurfaceMuted,
            ),
            label: Text(
              'Exit',
              style: AppTextStyles.caption.copyWith(fontSize: 11),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}
