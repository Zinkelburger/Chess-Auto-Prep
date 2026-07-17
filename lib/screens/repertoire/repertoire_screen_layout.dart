// Layout builders for the repertoire screen: the wide/compact arrangements,
// board zone, tools columns, Lines side panel with its drag handle, and the
// tools tab bar. Split out of repertoire_screen.dart (pure code motion; the
// tab labels and nav strip themselves now live in
// lib/widgets/repertoire/repertoire_tab_labels.dart and
// repertoire_nav_controls.dart).
part of '../repertoire_screen.dart';

mixin _RepertoireLayout
    on
        _RepertoireScreenStateBase,
        _RepertoireSessionHandlers,
        _RepertoireTabContent {
  Widget _buildWideLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final defaultWidth = (constraints.maxWidth * 0.24)
            .clamp(260.0, 400.0)
            .toDouble();
        final maxWidth = (constraints.maxWidth * 0.45)
            .clamp(_kLinesPanelMinWidth, constraints.maxWidth)
            .toDouble();
        final panelWidth = (_linesPanelWidth ?? defaultWidth)
            .clamp(_kLinesPanelMinWidth, maxWidth)
            .toDouble();
        // The board zone needs a bounded width: the bars under the board
        // (build-session, ephemeral finding) hold Rows with Expanded
        // children, which cannot lay out under the Row's unbounded width.
        // maxHeight matches the width the square board resolves to anyway
        // (board side + padding), so the no-bar geometry is unchanged.
        final boardZoneWidth = constraints.maxHeight.clamp(
          0.0,
          constraints.maxWidth * 0.5,
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: boardZoneWidth, child: _buildBoardZone()),
            _verticalZoneDivider(),
            Expanded(child: _buildWideToolsColumn()),
            if (_linesPanelCollapsed)
              _verticalZoneDivider()
            else
              _buildLinesPanelDragHandle(maxWidth),
            _buildLinesSidePanel(panelWidth),
          ],
        );
      },
    );
  }

  /// Divider between the PGN tools column and the Lines side panel; drag it
  /// to resize the panel.
  Widget _buildLinesPanelDragHandle(double maxWidth) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          // Panel spans from the handle to the right edge of the screen body.
          final localX = box.globalToLocal(details.globalPosition).dx;
          final newWidth = (box.size.width - localX)
              .clamp(_kLinesPanelMinWidth, maxWidth)
              .toDouble();
          setState(() => _linesPanelWidth = newWidth);
        },
        onHorizontalDragEnd: (_) => _saveLinesPanelWidth(),
        child: SizedBox(
          width: 7,
          child: Center(child: Container(width: 1, color: AppColors.outline)),
        ),
      ),
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
                : (_ephemeralFen ?? _controller.fen),
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
        if (_ephemeralFinding != null)
          EphemeralFindingBar(
            finding: _ephemeralFinding!,
            onGoToPosition: _createNewLineFromEphemeral,
            onDismiss: () {
              setState(() {
                _ephemeralFinding = null;
                _ephemeralFen = null;
              });
            },
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
    final theme = Theme.of(context);
    if (_linesPanelCollapsed) {
      return InkWell(
        onTap: () => _setLinesPanelCollapsed(false),
        child: SizedBox(
          width: 28,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Tooltip(
                message: 'Show lines (L)',
                child: const Icon(
                  Icons.keyboard_double_arrow_left,
                  size: 16,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
              const SizedBox(height: 12),
              RotatedBox(
                quarterTurns: 1,
                child: Text(
                  _isBuildSessionActive
                      ? 'Session'
                      : _isDraftActive
                      ? 'Draft'
                      : 'Lines (${_controller.repertoireLines.length})',
                  style: AppTextStyles.caption.copyWith(
                    fontSize: 11,
                    color: _isBuildSessionActive
                        ? theme.colorScheme.primary
                        : _isDraftActive
                        ? AppColors.warning
                        : AppColors.onSurfaceMuted,
                    fontWeight: _isBuildSessionActive || _isDraftActive
                        ? FontWeight.w600
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      width: width,
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.keyboard_double_arrow_right, size: 16),
                onPressed: () => _setLinesPanelCollapsed(true),
                tooltip: 'Hide lines (L)',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              Expanded(
                child: TabBar(
                  controller: _sidePanelTabController,
                  // Scrollable so narrow panel widths shrink the bar instead
                  // of overflowing the tab labels.
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [_buildLinesTabLabel(), _buildTreeTabLabel()],
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                  indicatorSize: TabBarIndicatorSize.label,
                  dividerHeight: 0,
                ),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _sidePanelTabController,
              physics: const NeverScrollableScrollPhysics(),
              children: [_buildSecondTabContent(), _buildTreeTabContent()],
            ),
          ),
        ],
      ),
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
      hasTraps: _traps.isNotEmpty,
    );
  }

  Widget _buildTreeTabLabel() => const RepertoireTreeTabLabel();

  Widget _buildNavControls() {
    return RepertoireNavControls(
      onGoToStart: () => _controller.loadMoveSequence([]),
      onGoBack: _sessionAwareGoBack,
      onGoForward: _sessionAwareGoForward,
      onGenerateFromHere: _generateFromHere,
      onFlipBoard: () => setState(() => _boardFlipped = !_boardFlipped),
    );
  }

  Widget _verticalZoneDivider() {
    return Container(width: 1, color: AppColors.outline);
  }
}
