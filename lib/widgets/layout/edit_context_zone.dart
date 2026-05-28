/// Context panel in Edit mode.
///
/// Chip-switched sub-views: browse candidates, engine PV, expectimax lines,
/// or opening / eval tree. Content can be injected for isolated testing or
/// built from [RepertoireController] when wired into the repertoire screen.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show uciToSan;
import 'package:chess_auto_prep/widgets/engine/expectimax_lines_pane.dart';
import 'package:chess_auto_prep/widgets/engine/unified_engine_pane.dart';
import 'package:chess_auto_prep/widgets/layout/empty_state_placeholder.dart';
import 'package:chess_auto_prep/widgets/opening_tree_widget.dart';
import 'repertoire_mode.dart';

/// Descriptor for one chip in [EditContextZone].
typedef EditContextChipSpec = ({EditContextView view, String label, IconData icon});

/// Default chip order for the Edit context panel.
const kEditContextChips = <EditContextChipSpec>[
  (view: EditContextView.browse, label: 'Browse', icon: Icons.travel_explore),
  (view: EditContextView.engine, label: 'Engine', icon: Icons.bolt),
  (view: EditContextView.expectimax, label: 'Expectimax', icon: Icons.analytics),
  (view: EditContextView.tree, label: 'Tree', icon: Icons.account_tree),
];

/// Chip-switched context column for Edit mode (browse / engine / expectimax / tree).
class EditContextZone extends StatefulWidget {
  final EditContextView initialView;

  /// When set, chip selection is mirrored here (read on init, written on change).
  final ValueNotifier<EditContextView>? selectedViewNotifier;

  final ValueChanged<EditContextView>? onViewChanged;

  /// Injected content — preferred for tests and custom wiring.
  final Widget? browseContent;
  final Widget? engineContent;
  final Widget? expectimaxContent;
  final Widget? treeContent;

  /// Subset of chips to show; defaults to all four.
  final List<EditContextChipSpec>? chips;

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
    this.treeContent,
    this.chips,
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
  late EditContextView _view;

  List<EditContextChipSpec> get _chips => widget.chips ?? kEditContextChips;

  @override
  void initState() {
    super.initState();
    _view = widget.selectedViewNotifier?.value ?? widget.initialView;
    widget.selectedViewNotifier?.addListener(_onExternalViewChanged);
  }

  @override
  void didUpdateWidget(covariant EditContextZone oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedViewNotifier != widget.selectedViewNotifier) {
      oldWidget.selectedViewNotifier?.removeListener(_onExternalViewChanged);
      widget.selectedViewNotifier?.addListener(_onExternalViewChanged);
      if (widget.selectedViewNotifier != null) {
        _view = widget.selectedViewNotifier!.value;
      }
    }
  }

  @override
  void dispose() {
    widget.selectedViewNotifier?.removeListener(_onExternalViewChanged);
    super.dispose();
  }

  void _onExternalViewChanged() {
    final external = widget.selectedViewNotifier!.value;
    if (external != _view && mounted) {
      setState(() => _view = external);
    }
  }

  void _selectView(EditContextView view) {
    if (_view == view) return;
    setState(() => _view = view);
    widget.selectedViewNotifier?.value = view;
    widget.onViewChanged?.call(view);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildChipBar(context),
        const Divider(height: 1, color: AppColors.divider),
        Expanded(child: _buildContent()),
      ],
    );
  }

  Widget _buildChipBar(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final spec in _chips)
            _ContextChoiceChip(
              label: spec.label,
              icon: spec.icon,
              selected: _view == spec.view,
              onSelected: () => _selectView(spec.view),
              selectedColor: theme.colorScheme.primary,
            ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return switch (_view) {
      EditContextView.browse => _resolveBrowse(),
      EditContextView.engine => _resolveEngine(),
      EditContextView.expectimax => _resolveExpectimax(),
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
    if (controller?.openingTree == null) return null;

    return OpeningTreeWidget(
      tree: controller!.openingTree!,
      repertoireLines: controller.repertoireLines,
      currentMoveSequence: controller.currentMoveSequence,
      onMoveSelected: controller.userPlayedMove,
    );
  }
}

class _ContextChoiceChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onSelected;
  final Color selectedColor;

  const _ContextChoiceChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onSelected,
    required this.selectedColor,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: selected ? selectedColor : AppColors.onSurfaceDim,
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
      selected: selected,
      onSelected: (_) => onSelected(),
      visualDensity: VisualDensity.compact,
      showCheckmark: false,
    );
  }
}
