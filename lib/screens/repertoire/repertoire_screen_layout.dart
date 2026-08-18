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
  Widget _buildWideLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelWidth = _layout.resolveLinesPanelWidth(constraints.maxWidth);
        // The board zone needs a bounded width: the bars under the board
        // (build-session, ephemeral finding) hold Rows with Expanded
        // children, which cannot lay out under the Row's unbounded width.
        final boardZoneWidth = _layout.boardZoneWidth(
          availableWidth: constraints.maxWidth,
          availableHeight: constraints.maxHeight,
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: boardZoneWidth, child: _buildBoardZone()),
            _verticalZoneDivider(),
            Expanded(child: _buildWideToolsColumn()),
            if (_layout.linesPanelCollapsed)
              _verticalZoneDivider()
            else
              RepertoireLinesPanelDragHandle(
                currentWidth: panelWidth,
                minWidth: RepertoireLayoutPrefs.minPanelWidth,
                maxWidth: RepertoireLayoutPrefs.maxLinesPanelWidth(
                  constraints.maxWidth,
                ),
                onWidthChanged: _layout.dragLinesPanelWidth,
                onDragEnd: _layout.saveLinesPanelWidth,
              ),
            _buildLinesSidePanel(panelWidth),
          ],
        );
      },
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
      onToggleExpectimax: InlineExpectimaxBar.toggle,
      onToggleLinesTab: () {
        if (_isCompactLayout) {
          _toolsTabController.animateTo(_toolsTabController.index == 1 ? 0 : 1);
        } else {
          unawaited(_layout.toggleLinesPanelCollapsed());
        }
      },
      onCollapseBottomPane: () {
        if (_buildSession.phase == BuildByPlayingPhase.exploring) {
          _buildSession.backToDecisionPoint();
          return true;
        }
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
          startTrap: _trapSession.trapAtFen(_controller.fen),
        );
      },
      onToggleEngine: InlineEngineBar.toggleEngine,
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

  Widget _buildBoardZone() {
    return Column(
      children: [
        Expanded(
          child: BoardZone(
            boardPreview: _boardPreview,
            fen: _isBuildSessionActive
                ? _buildSession.boardFen
                : (_ephemeralPreview?.fen ?? _controller.fen),
            positionFromFen: _positionFromFen,
            boardFlipped: _boardFlipped,
            onMove: _handleMove,
            annotations: buildAuditBoardAnnotations(
              result: _auditController.result,
              currentFen: _controller.fen,
            ),
          ),
        ),
        if (_isBuildSessionActive) BuildSessionBoardBar(session: _buildSession),
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
  /// Engine bars live inside PGN tab only.
  Widget _buildToolsColumn() {
    return Column(
      children: [
        _buildToolsTabBar(),
        Expanded(
          child: TabBarView(
            controller: _toolsTabController,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _buildPgnTabWithEngines(),
              _buildSecondTabContent(),
              _buildTreeTabContent(),
            ],
          ),
        ),
        _buildNavControls(),
      ],
    );
  }

  /// Wide-layout tools column: the PGN editor, always visible — the
  /// Lines/Draft and Tree surfaces live in the side panel to the right.
  Widget _buildWideToolsColumn() {
    return Column(
      children: [
        Expanded(child: _buildPgnTabWithEngines()),
        _buildNavControls(),
      ],
    );
  }

  /// Wide-layout side panel hosting the Lines/Draft and Tree surfaces so they
  /// stay clickable while the PGN editor is visible. Collapses to a thin
  /// strip.
  Widget _buildLinesSidePanel(double width) {
    return RepertoireLinesSidePanel(
      collapsed: _layout.linesPanelCollapsed,
      width: width,
      surface: _isBuildSessionActive
          ? RepertoireLinesSurface.session
          : _isDraftActive
          ? RepertoireLinesSurface.draft
          : RepertoireLinesSurface.lines,
      lineCount: _controller.repertoireLines.length,
      tabController: _sidePanelTabController,
      tabs: [_buildLinesTabLabel(), _buildTreeTabLabel()],
      children: [_buildSecondTabContent(), _buildTreeTabContent()],
      onCollapsedChanged: _layout.setLinesPanelCollapsed,
    );
  }

  Widget _buildToolsTabBar() {
    return TabBar(
      controller: _toolsTabController,
      tabs: [_buildPgnTabLabel(), _buildLinesTabLabel(), _buildTreeTabLabel()],
      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
      indicatorSize: TabBarIndicatorSize.label,
      dividerHeight: 1,
    );
  }

  Widget _buildPgnTabLabel() => const RepertoirePgnTabLabel();

  Widget _buildLinesTabLabel() {
    return RepertoireLinesTabLabel(
      isBuildSessionActive: _isBuildSessionActive,
      isDraftActive: _isDraftActive,
      hasTraps: _trapSession.hasTraps,
    );
  }

  Widget _buildTreeTabLabel() => const RepertoireTreeTabLabel();

  Widget _buildNavControls() {
    return RepertoireNavControls(
      onGoToStart: () => _controller.loadMoveSequence([]),
      onGoBack: _sessionAwareGoBack,
      onGoForward: _sessionAwareGoForward,
      onGenerateFromHere: _openGenerationDialog,
      onFlipBoard: () => setState(() => _boardFlipped = !_boardFlipped),
      // Compact stacks the board above the tools, so there is no width to
      // trade and the control would do nothing.
      boardSize: _isCompactLayout ? null : _layout.boardSize,
      onBoardSizeChanged: _isCompactLayout ? null : _layout.setBoardSize,
    );
  }

  Widget _verticalZoneDivider() {
    return Container(width: 1, color: AppColors.outline);
  }
}
