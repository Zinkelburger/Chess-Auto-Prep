/// Collapsible explorer section for the right pane.
///
/// Shows BrowsePanel (candidate moves from DB/tree) and optionally the
/// OpeningTreeWidget, in a collapsible section with a header toggle.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/browse/widgets/browse_panel.dart';
import '../features/repertoires/controllers/builder_workspace_controller.dart';
import '../models/build_tree_node.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/browse/services/candidate_service.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../services/coherence_service.dart';
import '../services/generation/fen_map.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/models/trap_line_info.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'labeled_toggle.dart';
import 'opening_tree_widget.dart';

class ExplorerSection extends StatefulWidget {
  final BuilderWorkspaceController controller;
  final BuildTree? tree;
  final FenMap? fenMap;
  final BoardPreviewController boardPreview;
  final CoherenceResult? coherenceResult;
  final List<TrapLineInfo> traps;
  final CoverageResult? coverageResult;
  final NavigationStack navigationStack;

  const ExplorerSection({
    super.key,
    required this.controller,
    this.tree,
    this.fenMap,
    required this.boardPreview,
    this.coherenceResult,
    this.traps = const [],
    this.coverageResult,
    required this.navigationStack,
  });

  @override
  State<ExplorerSection> createState() => _ExplorerSectionState();
}

class _ExplorerSectionState extends State<ExplorerSection> {
  static const _kExpanded = 'explorer_section.expanded';
  static const _kShowTree = 'explorer_section.show_tree';

  bool _expanded = true;
  bool _showTree = false;
  CandidateService? _candidateService;
  TrapIndexService? _trapIndexCache;
  int? _expandedTrapIndex;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPrefs());
    widget.controller.addListener(_onControllerChanged);
    _rebuildCandidateService();
    _rebuildTrapIndex();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ExplorerSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tree != widget.tree ||
        oldWidget.fenMap != widget.fenMap ||
        oldWidget.coverageResult != widget.coverageResult) {
      _rebuildCandidateService();
    }
    if (oldWidget.traps != widget.traps) {
      _rebuildTrapIndex();
    }
  }

  void _rebuildTrapIndex() {
    _trapIndexCache = widget.traps.isEmpty
        ? null
        : TrapIndexService(widget.traps);
  }

  void _rebuildCandidateService() {
    _candidateService = CandidateService(
      tree: widget.tree,
      fenMap: widget.fenMap,
      openingTree: widget.controller.document.openingGraph,
      coverage: widget.coverageResult,
      coverageService: CoverageService(),
    );
  }

  void _onControllerChanged() {
    _expandedTrapIndex = null;
    _rebuildCandidateService();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _expanded = prefs.getBool(_kExpanded) ?? true;
        _showTree = prefs.getBool(_kShowTree) ?? false;
      });
    } catch (_) {
      // Best-effort; failure here is non-fatal and intentionally ignored.
    }
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kExpanded, _expanded);
      await prefs.setBool(_kShowTree, _showTree);
    } catch (_) {
      // Best-effort; failure here is non-fatal and intentionally ignored.
    }
  }

  Future<void> _onCandidateTap(CandidateMove move) async {
    if (move.inRepertoire) {
      widget.controller.board.playMove(move.san);
      return;
    }
    try {
      await widget.controller.writer.addMoveAtPosition(
        fen: widget.controller.board.fen,
        san: move.san,
        pathFromRoot: widget.controller.board.currentMoveSequence,
      );
      widget.controller.board.playMove(move.san);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add ${move.san}: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _performUndo() async {
    try {
      await widget.controller.writer.undo();
    } catch (_) {
      // Best-effort; failure here is non-fatal and intentionally ignored.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasBrowseSource =
        widget.tree != null || _candidateService?.coverageService != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader(theme),
        if (_expanded && hasBrowseSource && _candidateService != null) ...[
          const Divider(height: 1),
          _buildBrowseContent(),
        ],
        if (_expanded && _showTree) ...[
          const Divider(height: 1),
          _buildTreeContent(),
        ],
      ],
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return InkWell(
      onTap: () {
        setState(() => _expanded = !_expanded);
        unawaited(_savePrefs());
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        color: theme.colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            Icon(_expanded ? Icons.expand_more : Icons.chevron_right, size: 16),
            const SizedBox(width: 4),
            const Text(
              'Explorer',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurfaceSoft,
              ),
            ),
            const Spacer(),
            if (_expanded)
              AppSwitch(
                label: 'Tree',
                value: _showTree,
                onChanged: (v) {
                  setState(() => _showTree = v);
                  unawaited(_savePrefs());
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowseContent() {
    final isOurTurn =
        widget.controller.board.position.turn ==
        (widget.controller.document.isRepertoireWhite
            ? Side.white
            : Side.black);

    return SizedBox(
      height: 180,
      child: BrowsePanel(
        fen: widget.controller.board.fen,
        pathFromRoot: widget.controller.board.currentMoveSequence,
        isOurTurn: isOurTurn,
        isWhiteRepertoire: widget.controller.document.isRepertoireWhite,
        candidateService: _candidateService!,
        boardPreview: widget.boardPreview,
        coherenceResult: widget.coherenceResult,
        currentMoves: widget.controller.board.currentMoveSequence,
        trapIndex: _trapIndexCache,
        expandedTrapIndex: _expandedTrapIndex,
        onCandidateTap: _onCandidateTap,
        onExpandTraps: (idx) {
          setState(() {
            _expandedTrapIndex = _expandedTrapIndex == idx ? null : idx;
          });
        },
        onTrapGo: (trap) {
          widget.navigationStack.push(
            NavigationEntry(
              tabIndex: 0,
              fen: widget.controller.board.fen,
              label:
                  'Explorer · ${widget.controller.board.currentMoveSequence.lastOrNull ?? 'start'}',
              reason: 'trap',
            ),
          );
          widget.controller.composeMoves(trap.movesSan);
        },
        onBack: widget.controller.board.goBack,
        onRoot: widget.controller.board.goToStart,
        canUndo: widget.controller.writer.canUndo,
        onUndo: _performUndo,
      ),
    );
  }

  Widget _buildTreeContent() {
    if (widget.controller.document.openingGraph == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('No opening tree available', style: AppTextStyles.caption),
      );
    }
    return SizedBox(
      height: 200,
      child: OpeningTreeWidget(
        tree: widget.controller.document.openingGraph!,
        showPgnSearch: false,
        repertoireLines: widget.controller.document.repertoireLines,
        currentMoveSequence: widget.controller.board.currentMoveSequence,
        onMoveSelected: (move) {
          widget.controller.board.userSelectedTreeMove(move);
        },
        onGoBack: () => widget.controller.board.goBack(),
        onGoForward: () => widget.controller.board.goForward(),
        onPositionSelected: (fen) {},
      ),
    );
  }
}
