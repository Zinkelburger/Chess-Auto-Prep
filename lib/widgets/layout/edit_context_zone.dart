/// Context panel beside the PGN editor in Edit mode.
///
/// TabBar sub-views: browse candidates, engine PV, expectimax lines, repertoire
/// lines browser, or opening tree. Content can be injected for tests or built
/// from [RepertoireController] when wired into the repertoire screen.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/widgets/engine/expectimax_lines_pane.dart';
import 'package:chess_auto_prep/widgets/engine/unified_engine_pane.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show uciToSan;
import 'package:chess_auto_prep/widgets/layout/empty_state_placeholder.dart';
import 'package:chess_auto_prep/features/eval_tree/widgets/compact_tree_outline.dart';
import 'package:chess_auto_prep/widgets/opening_tree_widget.dart';
import 'repertoire_mode.dart';

/// Descriptor for one tab in [EditContextZone].
typedef EditContextTabSpec = ({
  EditContextView view,
  String label,
  IconData icon,
});

/// Default tab order for the Edit context panel.
const kEditContextTabs = <EditContextTabSpec>[
  (view: EditContextView.browse, label: 'Browse', icon: Icons.travel_explore),
  (view: EditContextView.engine, label: 'Engine', icon: Icons.bolt),
  (view: EditContextView.expectimax, label: 'Expectimax', icon: Icons.analytics),
  (view: EditContextView.lines, label: 'Lines', icon: Icons.library_books),
  (view: EditContextView.tree, label: 'Tree', icon: Icons.account_tree),
];

/// Tab-switched context column for Edit mode.
class EditContextZone extends StatefulWidget {
  final EditContextView initialView;

  /// When set, tab selection is mirrored here (read on init, written on change).
  final ValueNotifier<EditContextView>? selectedViewNotifier;

  final ValueChanged<EditContextView>? onViewChanged;

  /// Injected content — preferred for tests and custom wiring.
  final Widget? browseContent;
  final Widget? engineContent;
  final Widget? expectimaxContent;
  final Widget? linesContent;
  final Widget? treeContent;

  /// Subset of tabs to show; defaults to all five.
  final List<EditContextTabSpec>? tabs;

  /// When true, tab switching is disabled (e.g. during generation).
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
    this.selectedViewNotifier,
    this.onViewChanged,
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

class _EditContextZoneState extends State<EditContextZone>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<EditContextTabSpec> get _tabs => widget.tabs ?? kEditContextTabs;

  int _indexForView(EditContextView view) {
    final index = _tabs.indexWhere((tab) => tab.view == view);
    return index >= 0 ? index : 0;
  }

  EditContextView _viewForIndex(int index) {
    if (index < 0 || index >= _tabs.length) {
      return _tabs.first.view;
    }
    return _tabs[index].view;
  }

  @override
  void initState() {
    super.initState();
    final initialView =
        widget.selectedViewNotifier?.value ?? widget.initialView;
    _tabController = TabController(
      length: _tabs.length,
      vsync: this,
      initialIndex: _indexForView(initialView),
    );
    _tabController.addListener(_onTabChanged);
    widget.selectedViewNotifier?.addListener(_onExternalViewChanged);
  }

  @override
  void didUpdateWidget(covariant EditContextZone oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedViewNotifier != widget.selectedViewNotifier) {
      oldWidget.selectedViewNotifier?.removeListener(_onExternalViewChanged);
      widget.selectedViewNotifier?.addListener(_onExternalViewChanged);
      if (widget.selectedViewNotifier != null) {
        _syncTabToView(widget.selectedViewNotifier!.value);
      }
    }
    if (oldWidget.tabsLocked != widget.tabsLocked) {
      _tabController.index = _tabController.index;
    }
  }

  @override
  void dispose() {
    widget.selectedViewNotifier?.removeListener(_onExternalViewChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onExternalViewChanged() {
    _syncTabToView(widget.selectedViewNotifier!.value);
  }

  void _syncTabToView(EditContextView view) {
    final index = _indexForView(view);
    if (_tabController.index != index && mounted) {
      _tabController.animateTo(index);
    }
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final view = _viewForIndex(_tabController.index);
    widget.selectedViewNotifier?.value = view;
    widget.onViewChanged?.call(view);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AbsorbPointer(
          absorbing: widget.tabsLocked,
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              for (final spec in _tabs)
                Tab(
                  text: spec.label,
                  icon: Icon(spec.icon, size: 16),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            physics: widget.tabsLocked
                ? const NeverScrollableScrollPhysics()
                : null,
            children: [
              for (final spec in _tabs)
                _ContextKeepAliveTab(child: _contentFor(spec.view)),
            ],
          ),
        ),
      ],
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
          controller.userPlayedMove(san);
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

    if (widget.tree == null || widget.treeConfig == null) {
      return const EmptyStatePlaceholder(
        icon: Icons.analytics_outlined,
        iconSize: 36,
        title: 'No tree loaded',
        subtitle: 'Generate a tree to see expectimax lines',
      );
    }

    return ExpectimaxLinesPane(
      fen: controller.fen,
      tree: widget.tree,
      config: widget.treeConfig,
      fenMap: widget.fenMap,
      isWhiteRepertoire: controller.isRepertoireWhite,
      boardPreview: preview,
      onMoveSelected: controller.userPlayedMove,
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
      onMoveSelected: controller.userPlayedMove,
    );
  }
}

class _ContextKeepAliveTab extends StatefulWidget {
  final Widget child;
  const _ContextKeepAliveTab({required this.child});

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