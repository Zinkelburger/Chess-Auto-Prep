/// Context panel beside the PGN editor in Edit mode.
///
/// Toggle chips choose visible panels; columns and vertical stacks are
/// user-arrangeable with draggable dividers. Layout persists via
/// [EditContextLayoutPrefs].
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/models/edit_context_layout.dart';
import 'package:chess_auto_prep/services/edit_context_layout_prefs.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/widgets/engine/expectimax_panel_host.dart';
import 'package:chess_auto_prep/widgets/engine/unified_engine_pane.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show uciToSan;
import 'package:chess_auto_prep/widgets/layout/empty_state_placeholder.dart';
import 'package:chess_auto_prep/features/eval_tree/widgets/compact_tree_outline.dart';
import 'package:chess_auto_prep/widgets/opening_tree_widget.dart';
import 'edit_context_layout_sheet.dart';
import 'edit_context_split_handle.dart';
import 'edit_context_tabs.dart';
import 'repertoire_mode.dart';

export 'edit_context_tabs.dart' show EditContextTabSpec, kEditContextTabs;

/// Multi-select context column for Edit mode with resizable pane layout.
class EditContextZone extends StatefulWidget {
  final EditContextView initialView;

  /// When set, visible panels are mirrored here (read on init, written on change).
  final ValueNotifier<Set<EditContextView>>? selectedViewsNotifier;

  final ValueChanged<Set<EditContextView>>? onViewsChanged;

  /// Injected content — preferred for tests and custom wiring.
  final Widget? browseContent;
  final Widget? engineContent;
  final Widget? expectimaxContent;
  final Widget? linesContent;
  final Widget? treeContent;

  /// Subset of panels to offer; defaults to all five.
  final List<EditContextTabSpec>? tabs;

  /// When true, panel toggling is disabled (e.g. during generation).
  final bool tabsLocked;

  /// Delegate mode: build default panes when content slots are null.
  final RepertoireController? controller;
  final BuildTree? tree;
  final TreeBuildConfig? treeConfig;
  final FenMap? fenMap;
  final BoardPreviewController? boardPreview;
  final bool isGenerating;
  final bool isGenerationPaused;

  const EditContextZone({
    super.key,
    required this.initialView,
    this.selectedViewsNotifier,
    this.onViewsChanged,
    this.browseContent,
    this.engineContent,
    this.expectimaxContent,
    this.linesContent,
    this.treeContent,
    this.tabs,
    this.tabsLocked = false,
    this.controller,
    this.tree,
    this.treeConfig,
    this.fenMap,
    this.boardPreview,
    this.isGenerating = false,
    this.isGenerationPaused = false,
  });

  @override
  State<EditContextZone> createState() => _EditContextZoneState();
}

class _EditContextZoneState extends State<EditContextZone> {
  late Set<EditContextView> _selectedViews;
  EditContextLayout _layout = EditContextLayout.defaultLayout;
  bool _layoutLoaded = false;
  List<EditContextTabSpec> get _tabs => widget.tabs ?? kEditContextTabs;

  @override
  void initState() {
    super.initState();
    _selectedViews = _resolveInitialSelection();
    widget.selectedViewsNotifier?.addListener(_onExternalViewsChanged);
    _loadLayout();
  }

  Future<void> _loadLayout() async {
    final saved = await EditContextLayoutPrefs.load();
    if (!mounted) return;
    setState(() {
      _layout = saved.syncVisible(_selectedViews);
      _layoutLoaded = true;
    });
  }

  Future<void> _persistLayout() async {
    await EditContextLayoutPrefs.save(_layout);
  }

  @override
  void didUpdateWidget(covariant EditContextZone oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedViewsNotifier != widget.selectedViewsNotifier) {
      oldWidget.selectedViewsNotifier?.removeListener(_onExternalViewsChanged);
      widget.selectedViewsNotifier?.addListener(_onExternalViewsChanged);
      if (widget.selectedViewsNotifier != null) {
        _syncFromNotifier(widget.selectedViewsNotifier!.value);
      }
    }
  }

  @override
  void dispose() {
    widget.selectedViewsNotifier?.removeListener(_onExternalViewsChanged);
    super.dispose();
  }

  Set<EditContextView> _resolveInitialSelection() {
    final external = widget.selectedViewsNotifier?.value;
    if (external != null && external.isNotEmpty) {
      return _normalizeSelection(external);
    }
    return {widget.initialView};
  }

  Set<EditContextView> _normalizeSelection(Set<EditContextView> views) {
    final allowed = _tabs.map((t) => t.view).toSet();
    final filtered = views.where(allowed.contains).toSet();
    if (filtered.isNotEmpty) return filtered;
    return {widget.initialView};
  }

  void _onExternalViewsChanged() {
    _syncFromNotifier(widget.selectedViewsNotifier!.value);
  }

  void _syncFromNotifier(Set<EditContextView> views) {
    final normalized = _normalizeSelection(views);
    if (setEquals(normalized, _selectedViews)) return;
    setState(() {
      _selectedViews = normalized;
      _layout = _layout.syncVisible(_selectedViews);
    });
  }

  void _notifySelection() {
    widget.selectedViewsNotifier?.value =
        Set<EditContextView>.from(_selectedViews);
    widget.onViewsChanged?.call(Set<EditContextView>.from(_selectedViews));
  }

  void _toggleView(EditContextView view, bool selected) {
    if (widget.tabsLocked) return;
    setState(() {
      if (selected) {
        _selectedViews = {..._selectedViews, view};
        _layout = _layout.syncVisible(_selectedViews);
      } else if (_selectedViews.length > 1) {
        _selectedViews = {..._selectedViews}..remove(view);
        _layout = _layout.syncVisible(_selectedViews);
      }
    });
    _notifySelection();
    _persistLayout();
  }

  void _setLayout(EditContextLayout layout) {
    setState(() => _layout = layout.syncVisible(_selectedViews));
    _persistLayout();
  }

  void _placeView(EditContextView view, int columnIndex) {
    _setLayout(_layout.placeView(view, columnIndex: columnIndex));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AbsorbPointer(
          absorbing: widget.tabsLocked,
          child: _buildChipBar(context),
        ),
        const Divider(height: 1),
        Expanded(
          child: _layoutLoaded
              ? _buildPanels()
              : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ],
    );
  }

  Widget _buildChipBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [for (final spec in _tabs) _chip(context, spec)],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.dashboard_customize_outlined, size: 20),
            tooltip: 'Arrange panes',
            visualDensity: VisualDensity.compact,
            onPressed: widget.tabsLocked
                ? null
                : () => showEditContextLayoutSheet(
                      context: context,
                      layout: _layout,
                      visibleViews: _selectedViews,
                      tabs: _tabs,
                      onLayoutChanged: _setLayout,
                    ),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, EditContextTabSpec spec) {
    final isSelected = _selectedViews.contains(spec.view);
    return GestureDetector(
      onLongPress:
          widget.tabsLocked ? null : () => _showPlaceMenu(context, spec),
      child: FilterChip(
        key: ValueKey('edit_context_chip_${spec.view.name}'),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              spec.icon,
              size: 14,
              color: isSelected ? Colors.teal : Colors.grey[500],
            ),
            const SizedBox(width: 4),
            Text(spec.label, style: const TextStyle(fontSize: 11)),
          ],
        ),
        selected: isSelected,
        onSelected: widget.tabsLocked ? null : (v) => _toggleView(spec.view, v),
        visualDensity: VisualDensity.compact,
        showCheckmark: false,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
    );
  }

  void _showPlaceMenu(BuildContext context, EditContextTabSpec spec) {
    if (!_selectedViews.contains(spec.view)) {
      _toggleView(spec.view, true);
    }
    final colCount = _layout.columns.length;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Place "${spec.label}" in…'),
              subtitle: const Text('Long-press chips for this menu'),
            ),
            for (var i = 0; i < colCount; i++)
              ListTile(
                leading: const Icon(Icons.view_column, size: 20),
                title: Text('Column ${i + 1}'),
                onTap: () {
                  Navigator.pop(ctx);
                  _placeView(spec.view, i);
                },
              ),
            ListTile(
              leading: const Icon(Icons.add, size: 20),
              title: const Text('New column'),
              onTap: () {
                Navigator.pop(ctx);
                _placeView(spec.view, colCount);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanels() {
    final synced = _layout.syncVisible(_selectedViews);
    if (synced.columns.isEmpty) {
      return const EmptyStatePlaceholder(
        icon: Icons.view_sidebar_outlined,
        title: 'No panels selected',
        subtitle: 'Enable at least one context panel above',
        iconSize: 36,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final hFlex = synced.normalizedHorizontalFlex();
        final columns = synced.columns;

        if (columns.length == 1) {
          return _buildColumn(
            columns.first,
            columnIndex: 0,
            maxHeight: constraints.maxHeight,
            maxWidth: constraints.maxWidth,
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < columns.length; i++) ...[
              if (i > 0)
                EditContextSplitHandle(
                  axis: EditContextSplitAxis.horizontal,
                  onDrag: (dx) => _resizeHorizontal(
                    i - 1,
                    dx,
                    constraints.maxWidth,
                  ),
                ),
              Expanded(
                flex: (hFlex[i] * 1000).round().clamp(1, 10000),
                child: _buildColumn(
                  columns[i],
                  columnIndex: i,
                  maxHeight: constraints.maxHeight,
                  maxWidth: constraints.maxWidth * hFlex[i],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  void _resizeHorizontal(int leftIndex, double deltaPx, double totalWidth) {
    if (leftIndex < 0 || leftIndex >= _layout.columns.length - 1) return;
    final cols = List<EditContextColumnLayout>.from(_layout.columns);
    final left = cols[leftIndex].horizontalFlex;
    final right = cols[leftIndex + 1].horizontalFlex;
    final pairSum = left + right;
    final shift = deltaPx / totalWidth * pairSum * cols.length;
    final newLeft = (left + shift).clamp(pairSum * 0.12, pairSum * 0.88);
    cols[leftIndex] = cols[leftIndex].copyWith(horizontalFlex: newLeft);
    cols[leftIndex + 1] =
        cols[leftIndex + 1].copyWith(horizontalFlex: pairSum - newLeft);
    _setLayout(EditContextLayout(columns: cols));
  }

  void _resizeVertical(
    int columnIndex,
    int dividerIndex,
    double deltaPx,
    double totalHeight,
  ) {
    final col = _layout.columns[columnIndex];
    if (dividerIndex < 0 || dividerIndex >= col.views.length - 1) return;
    final vFlex = col.normalizedVerticalFlex();
    final left = vFlex[dividerIndex];
    final right = vFlex[dividerIndex + 1];
    final pairSum = left + right;
    final shift = deltaPx / totalHeight * pairSum * col.views.length;
    final newLeft = (left + shift).clamp(pairSum * 0.12, pairSum * 0.88);
    final newFlex = List<double>.from(vFlex);
    newFlex[dividerIndex] = newLeft;
    newFlex[dividerIndex + 1] = pairSum - newLeft;
    final cols = List<EditContextColumnLayout>.from(_layout.columns);
    cols[columnIndex] = col.copyWith(verticalFlex: newFlex);
    _setLayout(EditContextLayout(columns: cols));
  }

  Widget _buildColumn(
    EditContextColumnLayout col, {
    required int columnIndex,
    required double maxHeight,
    required double maxWidth,
  }) {
    final views = col.views.where((v) => _selectedViews.contains(v)).toList();
    if (views.isEmpty) {
      return const SizedBox.shrink();
    }
    if (views.length == 1) {
      return _panelShell(views.first, _panelFor(views.first));
    }

    final vFlexAll = col.normalizedVerticalFlex();
    final vFlex = [
      for (final v in views) vFlexAll[col.views.indexOf(v)],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < views.length; i++) ...[
          if (i > 0)
            EditContextSplitHandle(
              axis: EditContextSplitAxis.vertical,
              onDrag: (dy) => _resizeVertical(
                columnIndex,
                i - 1,
                dy,
                maxHeight,
              ),
            ),
          Expanded(
            flex: (vFlex[i] * 1000).round().clamp(1, 10000),
            child: _panelShell(views[i], _panelFor(views[i])),
          ),
        ],
      ],
    );
  }

  Widget _panelShell(EditContextView view, Widget child) {
    final label =
        _tabs.where((t) => t.view == view).map((t) => t.label).firstOrNull;
    if (label == null) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.grey.withValues(alpha: 0.12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Colors.grey[400],
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: child),
      ],
    );
  }

  Widget _panelFor(EditContextView view) {
    // Rebuild [child] each zone update so tree/generation props stay current.
    // [AutomaticKeepAliveClientMixin] on the shell preserves panel state.
    return _ContextKeepAliveTab(
      key: ValueKey(view),
      child: _contentFor(view),
    );
  }

  Widget _contentFor(EditContextView view) {
    return switch (view) {
      EditContextView.browse => _resolveBrowse(),
      EditContextView.engine => _resolveEngine(),
      EditContextView.expectimax => _resolveExpectimax(),
      EditContextView.lines => _resolveLines(),
      EditContextView.tree => _resolveTree(),
    };
  }

  Widget _resolveBrowse() {
    if (widget.browseContent != null) return widget.browseContent!;
    return const EmptyStatePlaceholder(
      icon: Icons.travel_explore,
      iconSize: 36,
      title: 'Browse not configured',
      subtitle: 'Pass browseContent or wire BrowsePanel from the parent',
    );
  }

  Widget _resolveEngine() {
    if (widget.engineContent != null) return widget.engineContent!;
    final built = _buildDefaultEngine();
    if (built != null) return built;
    return _missingSlot('Engine', 'engineContent');
  }

  Widget _resolveExpectimax() {
    if (widget.expectimaxContent != null) return widget.expectimaxContent!;
    final built = _buildDefaultExpectimax();
    if (built != null) return built;
    return _missingSlot('Expectimax', 'expectimaxContent');
  }

  Widget _resolveLines() {
    if (widget.linesContent != null) return widget.linesContent!;
    return _missingSlot('Lines', 'linesContent');
  }

  Widget _resolveTree() {
    if (widget.treeContent != null) return widget.treeContent!;
    final built = _buildDefaultTree();
    if (built != null) return built;
    return _missingSlot('Tree', 'treeContent or EvalTreeTab');
  }

  Widget _missingSlot(String label, String hint) {
    return EmptyStatePlaceholder(
      icon: Icons.widgets_outlined,
      iconSize: 36,
      title: '$label not configured',
      subtitle: 'Pass $hint',
    );
  }

  Widget? _buildDefaultEngine() {
    final controller = widget.controller;
    final preview = widget.boardPreview;
    if (controller == null || preview == null) return null;

    return UnifiedEnginePane(
      fen: controller.fen,
      isActive: !widget.isGenerating || widget.isGenerationPaused,
      isUserTurn: controller.position.turn ==
          (controller.isRepertoireWhite ? Side.white : Side.black),
      currentMoveSequence: controller.currentMoveSequence,
      isWhiteRepertoire: controller.isRepertoireWhite,
      boardPreview: preview,
      onMoveSelected: (uciMove) {
        final san = uciToSan(controller.fen, uciMove);
        if (san != uciMove) {
          controller.playMove(san);
        }
      },
      onLineMoveTapped: (sanMoves, index) {
        controller.applyLineFromCurrent(sanMoves, index);
        preview.clearPreview();
      },
    );
  }

  Widget? _buildDefaultExpectimax() {
    final controller = widget.controller;
    final preview = widget.boardPreview;
    if (controller == null || preview == null) return null;

    return ExpectimaxPanelHost(
      controller: controller,
      tree: widget.tree,
      treeConfig: widget.treeConfig,
      fenMap: widget.fenMap,
      boardPreview: preview,
      isGenerating: widget.isGenerating,
      isGenerationPaused: widget.isGenerationPaused,
      autoComputeEnabled: true,
      onMoveSelected: controller.playMove,
      onLineMoveClicked: (sanMoves, index) {
        controller.applyLineFromCurrent(sanMoves, index);
        preview.clearPreview();
      },
    );
  }

  Widget? _buildDefaultTree() {
    final controller = widget.controller;
    if (controller == null) return null;

    if (widget.tree != null) {
      return CompactTreeOutline(
        tree: widget.tree!,
        playAsWhite: controller.isRepertoireWhite,
        currentFen: controller.fen,
        onNodeTapped: (node) {
          final startMoves = widget.tree!.startMoves.trim().isEmpty
              ? const <String>[]
              : widget.tree!.startMoves.trim().split(RegExp(r'\s+'));
          final movePath = [...startMoves, ...node.getLineSan()];
          controller.navigateToLineMove(movePath);
        },
      );
    }

    if (controller.openingTree == null) return null;

    return OpeningTreeWidget(
      tree: controller.openingTree!,
      repertoireLines: controller.repertoireLines,
      currentMoveSequence: controller.currentMoveSequence,
      onMoveSelected: controller.userSelectedTreeMove,
      onGoBack: controller.goBack,
      onGoForward: controller.goForward,
    );
  }
}

class _ContextKeepAliveTab extends StatefulWidget {
  final Widget child;
  const _ContextKeepAliveTab({super.key, required this.child});

  @override
  State<_ContextKeepAliveTab> createState() => _ContextKeepAliveTabState();
}

class _ContextKeepAliveTabState extends State<_ContextKeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
