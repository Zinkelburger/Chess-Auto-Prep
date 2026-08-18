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
  /// Wide layout, left to right: the outline (chapters and lines), the
  /// board, the PGN editor, and the analysis panel (engine, database, tree).
  /// What the repertoire *contains* on the left, the *position* in the
  /// middle, *evidence about the position* on the right.
  Widget _buildWideLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final outlineWidth = _layout.outlinePanelCollapsed
            ? 28.0
            : _layout.resolveOutlinePanelWidth(constraints.maxWidth);
        final panelWidth = _layout.linesPanelCollapsed
            ? 28.0
            : _layout.resolveLinesPanelWidth(constraints.maxWidth);
        // The board zone needs a bounded width: the bars under the board
        // (build-session, ephemeral finding) hold Rows with Expanded
        // children, which cannot lay out under the Row's unbounded width.
        // It sizes against what is left once both side columns are placed,
        // so opening the outline never crowds the PGN editor out.
        final boardZoneWidth = _layout.boardZoneWidth(
          availableWidth: constraints.maxWidth - outlineWidth - panelWidth,
          availableHeight: constraints.maxHeight,
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildOutlineSidePanel(outlineWidth),
            if (_layout.outlinePanelCollapsed)
              _verticalZoneDivider()
            else
              RepertoireLinesPanelDragHandle(
                currentWidth: outlineWidth,
                minWidth: RepertoireLayoutPrefs.minPanelWidth,
                maxWidth: RepertoireLayoutPrefs.maxLinesPanelWidth(
                  constraints.maxWidth,
                ),
                panelOnLeft: true,
                onWidthChanged: _layout.dragOutlinePanelWidth,
                onDragEnd: _layout.saveOutlinePanelWidth,
              ),
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
            _buildAnalysisSidePanel(panelWidth),
          ],
        );
      },
    );
  }

  /// The left column: the outline (or, while one runs, the build-by-playing
  /// session / games draft that is adding lines to it), collapsible to a
  /// strip.
  Widget _buildOutlineSidePanel(double width) {
    if (_layout.outlinePanelCollapsed) {
      final surface = _isBuildSessionActive
          ? RepertoireLinesSurface.session
          : _isDraftActive
          ? RepertoireLinesSurface.draft
          : RepertoireLinesSurface.lines;
      return RepertoireLinesSidePanel(
        collapsed: true,
        width: width,
        surface: surface,
        lineCount: _controller.repertoireLines.length,
        tabController: _sidePanelTabController,
        tabs: const [],
        children: const [],
        stripLabel: 'Chapters',
        hideTooltip: 'Hide chapters (L)',
        showTooltip: 'Show chapters (L)',
        onCollapsedChanged: _layout.setOutlinePanelCollapsed,
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
  Widget _buildOutlineColumnContent() => _buildSecondTabContent();

  /// The right column: Engine | Database | Tree, collapsible to a strip.
  Widget _buildAnalysisSidePanel(double width) {
    return RepertoireLinesSidePanel(
      collapsed: _layout.linesPanelCollapsed,
      width: width,
      surface: RepertoireLinesSurface.lines,
      lineCount: _controller.repertoireLines.length,
      tabController: _sidePanelTabController,
      tabs: const [
        Tab(height: 30, child: Text('Engine', style: TextStyle(fontSize: 12))),
        Tab(
          height: 30,
          child: Text('Database', style: TextStyle(fontSize: 12)),
        ),
        Tab(height: 30, child: Text('Tree', style: TextStyle(fontSize: 12))),
      ],
      children: [
        _buildEngineTabContent(),
        _buildDatabaseTabContent(),
        _buildTreeTabContent(),
      ],
      stripLabel: 'Analysis',
      hideTooltip: 'Hide analysis panel',
      showTooltip: 'Show analysis panel',
      onCollapsedChanged: _layout.setLinesPanelCollapsed,
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
          unawaited(_layout.toggleOutlinePanelCollapsed());
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

  /// Wide-layout tools column: the PGN editor, always visible. The engine
  /// and database live in the analysis panel to the right, the chapters and
  /// lines in the outline to the left.
  Widget _buildWideToolsColumn() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4.0),
            child: _buildPgnTab(),
          ),
        ),
        _buildNavControls(),
      ],
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
