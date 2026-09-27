// Body builders for the PGN viewer: full-screen view, board pane, tabbed
// side panel, game tab (engine bar + movetext + nav bar, plus the empty
// states), and the amend-mode bar. Part of pgn_viewer_screen.dart.
part of 'pgn_viewer_screen.dart';

/// Board-pane / side-panel / game-tab builders, split out of
/// [_PgnViewerScreenState].
mixin _PaneBuildersMixin on State<PgnViewerScreen>, _AppBarBuildersMixin {
  ({String fen, String? uci})? get _engineThreat;
  void _setEngineThreat(String fen, String? uci);
  GameAnalysisController get _analysisController;
  PgnWorkspace get _tabController;
  void _closePanel(int id);
  Widget _buildFilterWorkspace();
  void _handleBoardMove(String san);
  Future<void> _leaveSolitaire();
  void _analyseSolitaireGame();
  Future<void> _guardingSolitaireProgress(VoidCallback action);
  List<SolitaireTrophy> get _detectedTrophies;
  Future<void> _detectTrophies();
  DeviationReport? get _deviationReport;
  void _openInBuilder(DeviationReport report);
  void _showLineTab();
  bool get _lineTabVisited;
  void _showLinePosition(Position position);
  void _onGamePosition(Position position);
  Position? get _gamePanePosition;
  LiveExplorerService get _explorer;
  ExplorerMove? get _explorerHoverMove;
  void _setExplorerHover(ExplorerMove? move);
  Future<void> _openExplorerGame(ExplorerGame game);
  bool? _myColorIn(Map<String, String> headers);
  List<String> _currentGameSans(PgnGameEntry entry);

  Set<String> get _boardRecentMoveSquares {
    if (_document.reading.tree.showOpeningTree)
      return _document.reading.tree.recentMoveSquares;
    final reader = _activeMovetextController;
    // A filter position or a newly opened pane may not belong to this reader.
    // Never carry the hidden reader's last move onto a different board.
    if (reader.currentFen != _document.reading.currentPosition.fen)
      return const {};
    return reader.recentMoveSquares;
  }

  Widget _buildFullScreenView(ThemeData theme) {
    final coversReference =
        _onLineTab || _tabController.index == PgnWorkspace.filters;
    return FullscreenGameView(
      position: coversReference
          ? _gamePanePosition ?? _document.reading.currentPosition
          : _document.reading.currentPosition,
      boardFlipped: _document.presentation.boardFlipped,
      recentMoveSquares: coversReference
          ? _pgnWidgetController.recentMoveSquares
          : _boardRecentMoveSquares,
      gameLabel: _document.collection.visibleGames.isNotEmpty
          ? _document
                .collection
                .visibleGames[_document.collection.selectedIndex]
                .label
          : '',
      currentIndex: _document.collection.selectedIndex,
      totalGames: _document.collection.visibleGames.length,
      isAutoPlaying: _document.reading.playback.isPlaying,
      autoPlayDelaySec: _document.reading.playback.delaySec,
      autoNextGame: _document.reading.playback.autoNextGame,
      onBoardMove: (san) =>
          _document.reading.onBoardMove(san, reader: _pgnWidgetController),
      onPrev: _document.reading.prevGame,
      onNext: _document.reading.nextGame,
      onGoBack: () =>
          _document.reading.navigateBack(reader: _pgnWidgetController),
      onGoForward: () =>
          _document.reading.navigateForward(reader: _pgnWidgetController),
      onToggleAutoPlay: _document.reading.toggleAutoPlay,
      onExit: _document.presentation.exitFullScreen,
      onSetSpeed: _document.reading.playback.setSpeed,
      onSetAutoNext: _document.reading.playback.setAutoNextGame,
    );
  }

  Widget _buildBoardPane() {
    final solitaire = _document.reading.solitaire.controller;
    // Only a wrong guess gets an overlay; a correct one just plays out on the
    // board, which says it better than a popup could.
    final showWrongGuess =
        _document.reading.solitaire.isActive &&
        solitaire.feedback == SolitaireFeedback.incorrect;

    return Column(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  children: [
                    ChessBoardWidget(
                      position: _document.reading.currentPosition,
                      flipped: _document.presentation.boardFlipped,
                      recentMoveSquares: _boardRecentMoveSquares,
                      // A solitaire hint rings the piece that moves. A square tint
                      // would be the same mark the board puts under a piece you
                      // picked up yourself, so the hint has to be a different shape,
                      // not a different shade.
                      annotations: [
                        if (_engineThreat case final threat?
                            when _viewPreferences.engine &&
                                !_document.reading.solitaire.isActive &&
                                _tabController.index == PgnWorkspace.game &&
                                threat.fen ==
                                    _document.reading.currentPosition.fen &&
                                (threat.uci?.length ?? 0) >= 4)
                          BoardAnnotation(
                            orig: threat.uci!.substring(0, 2),
                            dest: threat.uci!.substring(2, 4),
                            brush: AnnotationBrush.red,
                          ),
                        if (_document.reading.solitaire.isActive &&
                            solitaire.hintSquare != null)
                          BoardAnnotation(
                            orig: solitaire.hintSquare!,
                            brush: AnnotationBrush.yellow,
                          ),
                      ],
                      // The explorer row under the pointer, tinted on the
                      // squares it would use — the same mark a played move
                      // leaves, so hovering reads as a rehearsal of it.
                      highlightedSquares: switch (_explorerHoverMove) {
                        final hover? => uciHighlightSquares(hover.uci),
                        null => const {},
                      },
                      onMove: (move) => _handleBoardMove(move.san),
                      // In solitaire, moves are allowed while guessing and again
                      // once the game completes (free exploration of the annotated
                      // game); only opponent auto-play locks the board.
                      enableUserMoves:
                          !_document.reading.solitaire.isActive ||
                          solitaire.waitingForUser ||
                          solitaire.isComplete,
                    ),
                    if (showWrongGuess)
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
                              color: AppColors.dangerSurface.withValues(
                                alpha: 0.85,
                              ),
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
          ),
        ),
        if (_document.collection.visibleGames.isNotEmpty)
          _buildCollectionNavigation(),
      ],
    );
  }

  Widget _buildSidePanel() {
    final showTabs = !_document.reading.solitaire.isActive;
    final tabs = showTabs ? _tabController.openTabs : [0];
    return Column(
      children: [
        if (showTabs)
          PgnWorkspaceBar(
            workspace: _tabController,
            onSelect: _showPanel,
            onClose: _closePanel,
          ),
        if (_deviationReport case final deviation?
            when showTabs &&
                _tabController.index == 0 &&
                !deviation.inBook &&
                !deviation.differentOpening)
          _DeviationBanner(report: deviation, onShowLine: _showLineTab),
        Expanded(
          child: IndexedStack(
            index: showTabs ? tabs.indexOf(_tabController.index) : 0,
            children: [
              for (final id in tabs)
                KeyedSubtree(
                  key: ValueKey('panel-$id'),
                  child: Offstage(
                    offstage: id != (showTabs ? _tabController.index : 0),
                    child: TickerMode(
                      enabled: id == (showTabs ? _tabController.index : 0),
                      child: switch (id) {
                        0 => _buildGameTab(),
                        1 => _buildLineTab(),
                        2 => _buildExplorerTab(),
                        3 => GameAnalysisTab(
                          analysisController: _analysisController,
                          pgnController: _pgnWidgetController,
                          currentPly: _document.reading.handle.mainLineIndex,
                          variationDepth: _pgnWidgetController.variationDepth,
                          gamePgnText:
                              _document.collection.visibleGames.isNotEmpty
                              ? _document
                                    .collection
                                    .visibleGames[_document
                                        .collection
                                        .selectedIndex]
                                    .pgnText
                              : null,
                          onAnnotatedMovetext:
                              _document.editor.persistMoveComments,
                          onUserNavigation: () {
                            if (!mounted) return;
                            _document.reading.playback.stop();
                            _reclaimFocus();
                          },
                          onAnalysisComplete: _detectTrophies,
                          detectedTrophies: _detectedTrophies,
                        ),
                        4 => _buildTreeTab(),
                        5 => _buildDatabaseTools(),
                        PgnWorkspace.filters => _buildFilterWorkspace(),
                        _ => const SizedBox.shrink(),
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTreeTab() => Column(
    children: [
      PgnTreeToolbar(
        config: _document.filters.selection.config,
        player: _document.collection.collectionPlayer,
        loading: _document.isLoading,
        hasActiveFilters: _document.filters.selection.active,
        onApplyPreset: _document.applySlicePreset,
        onApplyConfig: _document.recomputeAndApplyConfig,
        database: _tabController.databaseTree,
        onSourceChanged: (database) {
          if (!mounted) return;
          _tabController.databaseTree = database;
        },
        onFilter: _openSliceDialog,
      ),
      Expanded(
        child: _tabController.databaseTree
            ? _buildExplorerTab()
            : PgnOpeningTreePanel(
                tree: _document.reading.tree.openingTree,
                gameCount: _document.collection.visibleGames.length,
                includeVariations: _document.reading.tree.includeVariations,
                building: _document.reading.tree.buildingTree,
                processed: _document.reading.tree.treeBuildProcessed,
                total: _document.reading.tree.treeBuildTotal,
                currentMoveSequence:
                    _document.reading.tree.treeCurrentMoveSequence,
                wdlPerspective: _document.collection.wdlPerspective(
                  _document.filters.selection.config,
                ),
                matchingGames: [
                  for (final i in _document.reading.tree.gamesAtTreePosition())
                    _document.collection.visibleGames[i],
                ],
                currentMatchingIndex: _document.reading.tree
                    .gamesAtTreePosition()
                    .indexOf(_document.collection.selectedIndex),
                onIncludeVariationsChanged:
                    _document.reading.tree.setIncludeVariations,
                onMoveSelected: _document.reading.tree.onMoveSelected,
                onGoBack: _document.reading.tree.goBack,
                onGoForward: _document.reading.tree.goForward,
                onGameSelected: (game) {
                  if (!mounted) return;
                  final index = _document.collection.visibleGames.indexOf(game);
                  if (index >= 0) _document.reading.loadGameFromTree(index);
                },
              ),
      ),
    ],
  );

  Widget _buildCollectionNavigation() => GameNavBar(
    games: GameNavItem.fromEntries(
      _document.collection.games,
      visibleGames: _document.collection.visibleGames,
    ),
    currentIndex: _document.collection.selectedIndex,
    sortMode: _document.collection.sortMode,
    isAutoPlaying: !_onLineTab && _document.reading.playback.isPlaying,
    showPlayback: _viewPreferences.playback,
    onPrev: () =>
        unawaited(_guardingSolitaireProgress(_document.reading.prevGame)),
    onNext: () =>
        unawaited(_guardingSolitaireProgress(_document.reading.nextGame)),
    onGoToGame: (index) {
      unawaited(
        _guardingSolitaireProgress(() => _document.reading.goToGame(index)),
      );
      _reclaimFocus();
    },
    onToggleAutoPlay: _onLineTab ? null : _document.reading.toggleAutoPlay,
    isSolitaireMode: _document.reading.solitaire.isActive,
  );

  /// The Line tab: what my books say about the game on screen, and the prepared
  /// line itself on the same board.
  Widget _buildLineTab() {
    final games = _document.collection.visibleGames;
    if (!_lineTabVisited) {
      // Built but never looked at (see [_lineTabVisited]) — nothing to do yet.
      return const SizedBox.shrink();
    }
    if (games.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Open a game to check it against your books.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(
              fontSize: 13,
              color: AppColors.onSurfaceSoft,
            ),
          ),
        ),
      );
    }
    final entry = games[_document.collection.selectedIndex];
    return RepertoireLinePanel(
      // Keyed by game identity: a new game is a new question, and the panel's
      // colour guess and loaded line must not carry over.
      key: ValueKey('line_${_document.filePath}_${entry.label}'),
      gameLabel: entry.label,
      sans: _currentGameSans(entry),
      initialMeWhite: _myColorIn(entry.headers),
      lineController: _lineWidgetController,
      onShowPosition: _showLinePosition,
      onEditInBuilder: _openInBuilder,
    );
  }

  /// The opening explorer for the position on the board.  Playing a row
  /// makes the move on the game pane, as an ephemeral variation, exactly as
  /// dragging the piece would; the games it lists open through
  /// [_openExplorerGame].
  Widget _buildExplorerTab() {
    final sans = _pgnWidgetController.mainLineMoves;
    final ply = _document.reading.handle.mainLineIndex.clamp(0, sans.length);
    return OpeningExplorerPanel(
      service: _explorer,
      fen: _document.reading.currentPosition.fen,
      movePath: sans.sublist(0, ply),
      onPlayMove: _handleBoardMove,
      onHoverMove: _setExplorerHover,
      onOpenGame: _openExplorerGame,
    );
  }

  Widget _buildGameTab() {
    if (_document.collection.visibleGames.isEmpty &&
        _document.collection.games.isNotEmpty &&
        _document.filters.selection.active) {
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
              onPressed: _document.resetFilters,
              icon: const Icon(Icons.filter_alt_off),
              label: const Text('Show All Games'),
            ),
          ],
        ),
      );
    }
    if (_document.collection.visibleGames.isEmpty) {
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
              if (_viewerError != null) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _viewerError!,
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
              if (_document.libraryState.recentFiles.isNotEmpty) ...[
                const SizedBox(height: 24),
                // One column, one width: file names differ wildly in length,
                // and centring each row on its own made the list read as a
                // ragged pile rather than a list.
                SizedBox(
                  width: 380,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Recent',
                        style: AppTextStyles.caption.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final path in _document.libraryState.recentFiles)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Tooltip(
                            message: path,
                            waitDuration: const Duration(milliseconds: 600),
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
                                  children: [
                                    const Icon(
                                      Icons.description,
                                      size: 16,
                                      color: AppColors.onSurfaceMuted,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
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
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (_document.reading.restoringSession) return const SizedBox.shrink();
    final game =
        _document.collection.visibleGames[_document.collection.selectedIndex];
    return Column(
      children: [
        if (_viewPreferences.engine &&
            !_document.reading.solitaire.isActive &&
            !_document.reading.solitaire.isConfiguring)
          InlineEngineBar(
            onThreatChanged: _setEngineThreat,
            isActive: _tabController.index == PgnWorkspace.game,
            fen: _document.reading.currentPosition.fen,
            previewFlipped: _document.presentation.boardFlipped,
            onLineMoveTapped: _document.reading.onEngineLineMoveTapped,
          ),
        // One solitaire strip at a time: the choices, then the session, then
        // what to do with the finished game.
        if (_document.reading.solitaire.setup case final setup?)
          SolitaireSetupStrip(
            userIsWhite: setup.userIsWhite,
            fromCurrentMove: setup.fromCurrentMove,
            includeVariations: setup.includeVariations,
            canStartHere: setup.canStartHere,
            hasSidelines: setup.hasSidelines,
            startHereLabel: setup.startHereLabel,
            userMovesToGuess: setup.userMovesToGuess,
            revealDelaySeconds:
                _document.reading.solitaire.controller.revealDelaySec,
            onUserSideChanged: (value) =>
                _document.reading.solitaire.updateSetup(userIsWhite: value),
            onFromCurrentMoveChanged: (value) =>
                _document.reading.solitaire.updateSetup(fromCurrentMove: value),
            onIncludeVariationsChanged: (value) => _document.reading.solitaire
                .updateSetup(includeVariations: value),
            onRevealDelayChanged: (value) =>
                unawaited(_document.reading.setSolitaireRevealDelay(value)),
            onCancel: _document.reading.solitaire.cancelSetup,
            onBegin: _document.reading.solitaire.begin,
          ),
        if (_document.reading.solitaire.isActive &&
            !_document.reading.solitaire.controller.isComplete)
          SolitaireStatusBar(
            controller: _document.reading.solitaire.controller,
            onHint: _document.reading.solitaire.hintCurrentMove,
            onReveal: _document.reading.solitaire.revealCurrentMove,
            onExit: () => unawaited(_leaveSolitaire()),
          ),
        if (_document.reading.solitaire.isActive &&
            _document.reading.solitaire.controller.isComplete)
          SolitaireCompleteBanner(
            controller: _document.reading.solitaire.controller,
            onNextGame: _document.reading.nextGame,
            onCopyPgn: _copyCurrentGamePgn,
            onAddToStudy: _addCurrentGameToStudy,
            onAnalyse: _analyseSolitaireGame,
            onExit: () => unawaited(_leaveSolitaire()),
          ),
        if (_viewPreferences.showOpening)
          PgnOpeningLabel(headers: game.headers),
        if (!_document.reading.solitaire.isActive &&
            (_editMode || _showSaveAction || _viewerError != null))
          _buildEditModeBar(),
        Expanded(
          child: PgnViewerWidget(
            showStartEndButtons: true,
            showReadingOptions: false,
            key: ValueKey('game_${_document.collection.selectedIndex}'),
            pgnText: game.pgnText,
            controller: _pgnWidgetController,
            initialFen: _document.reading.pgnInitialFen,
            // Through the screen, not straight to the controller: it remembers
            // where the game's cursor is so leaving the Line tab can put the
            // board back (see [_onGamePosition]).
            onPositionChanged: (position) {
              if (!mounted ||
                  _document.collection.visibleGames.isEmpty ||
                  !identical(
                    _document.collection.visibleGames[_document
                        .collection
                        .selectedIndex],
                    game,
                  )) {
                return;
              }
              _onGamePosition(position);
            },
            // Bound to this game object: the annotation panel debounces its
            // saves, which may flush after the user switches games.
            onCommentsChanged: (movetext) => _document.persistMoveCommentsFor(
              game,
              movetext,
              // A finished solitaire game annotates itself — every guess
              // gets a note and every wrong try a sideline. That belongs
              // to the session: it shows in the movetext and rides along
              // with Copy PGN and Add to study, but it does not go back
              // into the file the reader opened.
              writeToFile: !_document.reading.solitaire.isActive,
            ),
            editMode: _editMode,
            persistMoves: !_document.reading.solitaire.isActive,
            bookFormatting: game.isCourseStyle,
            initialMainLineIndex: _document.reading.resumePlyFor(game),
            // The result is the answer to "how did this go?" — the one header
            // field a guesser must not see before the last move. Only once
            // the session is running, though: the setup strip still has the
            // whole game on screen behind it, so hiding the result there
            // would guard a door that is standing open.
            hideResult: _document.reading.solitaire.isActive,
            // Solitaire restarts on the new game once its moves are in.
            onGameLoaded: _document.reading.onViewerGameLoaded,
          ),
        ),
      ],
    );
  }

  Widget _buildEditModeBar() => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: const BoxDecoration(
      color: AppColors.surface,
      border: Border(bottom: BorderSide(color: AppColors.divider)),
    ),
    child: Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_viewerError != null)
          Text(
            _viewerError!,
            style: AppTextStyles.muted.copyWith(color: AppColors.ink),
          ),
        if (_showSaveAction)
          FilledButton.tonalIcon(
            onPressed: _document.editor.state.busy
                ? null
                : () => unawaited(_savePgn()),
            icon: const Icon(Icons.save_outlined, size: 18),
            key: const ValueKey('pgn-save-recovery'),
            label: Text(AppLocalizations.of(context).documentSaveRecovery),
          ),
        if (_editMode)
          TextButton.icon(
            onPressed: _toggleEditMode,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Done'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.ink,
              backgroundColor: AppColors.surfaceContainer,
              textStyle: AppTextStyles.bodyStrong,
            ),
          ),
      ],
    ),
  );
}

/// One-line banner above the side-panel tabs: where this game first left the
/// designated repertoire, with a jump to the Line tab that shows the prep.
class _DeviationBanner extends StatelessWidget {
  const _DeviationBanner({required this.report, required this.onShowLine});

  final DeviationReport report;
  final VoidCallback onShowLine;

  @override
  Widget build(BuildContext context) {
    final place = report.lineName ?? report.chapterName;
    final message = '${deviationVerdict(report)} · $place';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        // A deviation warns; running out of book is neutral information.
        color: report.bookEnded
            ? AppColors.surfaceElevated
            : Color.alphaBlend(
                AppColors.warningTint.withAlpha(20),
                AppColors.surface,
              ),
        border: const Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.fork_right,
            size: 20,
            color: report.bookEnded
                ? AppColors.onSurfaceMuted
                : AppColors.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          TextButton(
            onPressed: onShowLine,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              foregroundColor: AppColors.ink,
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Show my line',
              style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w400),
            ),
          ),
        ],
      ),
    );
  }
}
