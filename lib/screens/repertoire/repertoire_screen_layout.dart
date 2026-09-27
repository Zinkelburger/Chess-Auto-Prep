// How the repertoire screen arranges its zones: the wide and compact
// layouts, the board zone, the tools columns, and the tab bars. Every piece
// with behaviour of its own has been extracted to a widget under
// lib/features/repertoire/widgets/; what is left here is the arrangement and
// the wiring between those widgets and the screen's controllers.
part of '../repertoire_screen.dart';

mixin _RepertoireLayout
    on
        _RepertoireScreenStateBase,
        _RepertoireSessionHandlers,
        _RepertoireTabContent {
  /// Chapters, board and a moves / analysis column share the workspace.
  Widget _buildWideLayout() => LayoutBuilder(
    builder: (context, constraints) {
      // Opening a tall Jobs pane must not squeeze the workspace's controls
      // into negative space. The workspace scrolls only when it is very short.
      return SingleChildScrollView(
        child: SizedBox(
          height: constraints.maxHeight.clamp(500.0, double.infinity),
          child: _buildWideWorkspace(),
        ),
      );
    },
  );

  Widget _buildWideWorkspace() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final outlineWidth = _layout.outlinePanelCollapsed
            ? 28.0
            : _layout
                  .resolveOutlinePanelWidth(constraints.maxWidth)
                  .clamp(220.0, constraints.maxWidth * .24);
        final boardWidth = _layout.boardZoneWidth(
          availableWidth: constraints.maxWidth - outlineWidth - 32,
          availableHeight: constraints.maxHeight - 48,
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildOutlineSidePanel(outlineWidth),
              RepertoireOutlineResizeHandle(
                currentWidth: outlineWidth,
                minWidth: RepertoireLayoutPrefs.minPanelWidth,
                maxWidth: constraints.maxWidth * .24,
                onWidthChanged: _layout.dragOutlinePanelWidth,
                onDragEnd: _layout.saveOutlinePanelWidth,
              ),
              SizedBox(
                width: boardWidth,
                child: Column(
                  children: [
                    Expanded(child: _buildBoardZone()),
                    _buildNavControls(),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(child: _buildWideToolsColumn()),
            ],
          ),
        );
      },
    );
  }

  /// The left column: the outline, collapsible to a strip.
  Widget _buildOutlineSidePanel(double width) {
    if (_layout.outlinePanelCollapsed) {
      return RepertoireOutlineStrip(
        onExpand: () => _layout.setOutlinePanelCollapsed(false),
      );
    }
    return SizedBox(
      width: width,
      child: Column(children: [Expanded(child: _buildOutlineColumnContent())]),
    );
  }

  /// What fills the outline column — the same surface the compact layout's
  /// Lines tab shows: a running session or draft, the metrics browser, or
  /// the chapter/line tree.
  Widget _buildOutlineColumnContent() =>
      _cursorScoped((_) => _buildSecondTabContent());

  Widget _buildAnalysisDock() {
    return Column(
      children: [
        SizedBox(
          height: 34,
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _sidePanelTabController,
                  indicatorColor: AppColors.accent,
                  labelColor: AppColors.accent,
                  unselectedLabelColor: AppColors.onSurfaceMuted,
                  tabs: const [
                    Tab(text: 'Engine', height: 32),
                    Tab(text: 'Database', height: 32),
                  ],
                ),
              ),
              IconButton(
                tooltip: _layout.analysisCollapsed
                    ? 'Show analysis panel'
                    : 'Hide analysis panel',
                icon: Icon(
                  _layout.analysisCollapsed
                      ? Icons.expand_more
                      : Icons.expand_less,
                  size: 18,
                ),
                onPressed: _layout.toggleAnalysisCollapsed,
              ),
            ],
          ),
        ),
        if (!_layout.analysisCollapsed)
          Expanded(
            child: TabBarView(
              controller: _sidePanelTabController,
              children: [
                _cursorScoped((_) => _buildEngineTabContent()),
                _cursorScoped((_) => _buildDatabaseTabContent()),
              ],
            ),
          ),
      ],
    );
  }

  /// Keyboard shortcuts for the whole screen.
  ///
  /// Handlers that can decline (returning false) are how a key reaches
  /// the right owner: Esc unwinds the innermost thing that is open, and
  /// previous/next belong to the trap tour while it runs and to the findings
  /// panel otherwise.
  Widget _buildShortcuts({required Widget child}) {
    return RepertoireShortcuts(
      focusNode: _focusNode,
      onPasteFenFromClipboard: _pastePositionFromClipboard,
      onUndo: _performUndo,
      onToggleExpectimax: () => unawaited(_openGenerateTab()),
      onToggleLinesTab: () {
        if (_isCompactLayout) {
          _toolsTabController.animateTo(_toolsTabController.index == 1 ? 0 : 1);
        } else {
          unawaited(_layout.toggleOutlinePanelCollapsed());
        }
      },
      onCollapseBottomPane: () {
        if (_trapSession.closeTour()) return true;
        if (!_bottomPane.isCollapsed) {
          _closeBottomPane();
          return true;
        }
        return false;
      },
      onFlip: () => setState(() => _boardFlipped = !_boardFlipped),
      onToggleTrapTour: () {
        if (_trapSession.closeTour()) return true;
        // Start at the trap under the cursor when there is one.
        return _trapSession.openTour(
          startTrap: _trapSession.trapAtFen(_controller.board.fen),
        );
      },
      onToggleEngine: () => InlineEngineBar.toggleEngine(context),
      onFocusComment: PgnAnnotationPanel.focusActive,
      onGoBack: _sessionAwareGoBack,
      onGoForward: _sessionAwareGoForward,
      onGoToPreviousTrap: () => TrapNavigationButtons.goToPreviousTrap(
        trapIndex: _trapSession.index,
        controller: _controller,
      ),
      onGoToNextTrap: () => TrapNavigationButtons.goToNextTrap(
        trapIndex: _trapSession.index,
        controller: _controller,
      ),
      onNextFinding: () {
        // While the trap tour is open, previous/next belong to the tour.
        if (_trapSession.tourVisible) {
          _trapTourKey.currentState?.next();
          return true;
        }
        return _whenFindingsPanelHasKeys((panel) => panel.selectNext());
      },
      onPrevFinding: () {
        if (_trapSession.tourVisible) {
          _trapTourKey.currentState?.previous();
          return true;
        }
        return _whenFindingsPanelHasKeys((panel) => panel.selectPrevious());
      },
      onDismissFinding: () =>
          _whenFindingsPanelHasKeys((panel) => panel.dismissSelected()),
      child: child,
    );
  }

  Widget _buildCompactLayout() {
    return Column(
      children: [
        Expanded(flex: 4, child: _buildBoardZone()),
        const Divider(height: 1, thickness: 1),
        Expanded(flex: 5, child: _buildToolsColumn()),
      ],
    );
  }

  /// Rebuild [build]'s subtree on every controller notification, cursor
  /// moves included.  The screen itself only rebuilds on structural changes
  /// (see `_onRepertoireChanged`), so every zone that shows the position
  /// goes through here — the board, the PGN editor, the analysis tabs and
  /// the outline — and nothing else does.
  Widget _cursorScoped(WidgetBuilder build) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => build(context),
  );

  Widget _buildBoardZone() {
    return Column(
      children: [
        Expanded(
          child: _cursorScoped(
            (_) => RepertoireBoardPane(
              boardPreview: _boardPreview,
              fen: _ephemeralPreview?.fen ?? _controller.board.fen,
              positionFromFen: _positionFromFen,
              boardFlipped: _boardFlipped,
              onMove: _handleMove,
              annotations: _auditAnnotationsAt(_controller.board.fen),
              // An ephemeral finding puts a foreign position on the board;
              // the cursor's trail belongs to a different one.
              recentMoveSquares: _ephemeralPreview != null
                  ? const {}
                  : _controller.board.recentMoveTrail(),
            ),
          ),
        ),
        if (_ephemeralPreview != null)
          EphemeralFindingBar(
            finding: _ephemeralPreview!.finding,
            onGoToPosition: _createNewLineFromEphemeral,
            onDismiss: () => setState(() => _ephemeralPreview = null),
          ),
      ],
    );
  }

  /// Compact-layout tools pane: PGN | Lines/Draft | Tree tabs + nav.
  /// Live engine analysis has its own reference tab.
  Widget _buildToolsColumn() {
    return Column(
      children: [
        _buildToolsTabBar(),
        Expanded(
          child: TabBarView(
            controller: _toolsTabController,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _cursorScoped((_) => _buildPgnTab()),
              _cursorScoped((_) => _buildSecondTabContent()),
              _cursorScoped((_) => _buildDatabaseTabContent()),
              _cursorScoped((_) => _buildEngineTabContent()),
            ],
          ),
        ),
        _buildNavControls(),
      ],
    );
  }

  Widget _buildWideToolsColumn() {
    return Column(
      children: [
        Expanded(
          flex: 2,
          child: RepertoireWorkspacePanel(
            child: _cursorScoped((_) => _buildPgnTab()),
          ),
        ),
        const SizedBox(height: 8),
        if (_layout.analysisCollapsed)
          SizedBox(height: 34, child: _buildAnalysisDock())
        else
          Expanded(flex: 3, child: _buildAnalysisDock()),
      ],
    );
  }

  Widget _buildToolsTabBar() {
    return TabBar(
      controller: _toolsTabController,
      isScrollable: true,
      tabs: [
        _buildPgnTabLabel(),
        _buildLinesTabLabel(),
        const Tab(text: 'Database'),
        const Tab(text: 'Engine'),
      ],
      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
      indicatorSize: TabBarIndicatorSize.label,
      dividerHeight: 1,
    );
  }

  Widget _buildPgnTabLabel() => const RepertoirePgnTabLabel();

  Widget _buildLinesTabLabel() {
    return RepertoireLinesTabLabel(hasTraps: _trapSession.hasTraps);
  }

  Widget _buildNavControls() {
    return RepertoireNavControls(
      onGoToStart: _controller.board.goToStart,
      onGoBack: _sessionAwareGoBack,
      onGoForward: _sessionAwareGoForward,
      onGenerateFromHere: _openGenerateTab,
      onFlipBoard: () => setState(() => _boardFlipped = !_boardFlipped),
      // Compact stacks the board above the tools, so there is no width to
      // trade and the control would do nothing.
      boardSize: _isCompactLayout ? null : _layout.boardSize,
      onBoardSizeChanged: _isCompactLayout ? null : _layout.setBoardSize,
    );
  }
}
