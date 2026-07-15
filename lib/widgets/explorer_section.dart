/// Collapsible explorer section for the right pane.
///
/// Shows BrowsePanel (candidate moves from DB/tree) and optionally the
/// OpeningTreeWidget, in a collapsible section with a header toggle.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/browse/widgets/browse_panel.dart';
import '../core/repertoire_controller.dart';
import '../models/build_tree_node.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/browse/services/candidate_service.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../services/coherence_service.dart';
import '../services/generation/fen_map.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import 'opening_tree_widget.dart';

class ExplorerSection extends StatefulWidget {
  final RepertoireController controller;
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
    _loadPrefs();
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
      openingTree: widget.controller.openingTree,
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
      widget.controller.playMove(move.san);
      return;
    }
    try {
      await widget.controller.writer.addMoveAtPosition(
        fen: widget.controller.fen,
        san: move.san,
        pathFromRoot: widget.controller.currentMoveSequence,
      );
      widget.controller.playMove(move.san);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added ${move.san} to repertoire'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
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
      final undone = await widget.controller.writer.undo();
      if (!mounted || !undone) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Undid last repertoire add'),
          duration: Duration(seconds: 2),
        ),
      );
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
        _savePrefs();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        color: theme.colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            Icon(_expanded ? Icons.expand_more : Icons.chevron_right, size: 16),
            const SizedBox(width: 4),
            Text(
              'Explorer',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey[400],
              ),
            ),
            const Spacer(),
            if (_expanded)
              SizedBox(
                height: 20,
                child: FilterChip(
                  label: const Text('Tree', style: TextStyle(fontSize: 10)),
                  selected: _showTree,
                  onSelected: (_) {
                    setState(() => _showTree = !_showTree);
                    _savePrefs();
                  },
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                  padding: EdgeInsets.zero,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowseContent() {
    final isOurTurn =
        widget.controller.position.turn ==
        (widget.controller.isRepertoireWhite ? Side.white : Side.black);

    return SizedBox(
      height: 180,
      child: BrowsePanel(
        fen: widget.controller.fen,
        pathFromRoot: widget.controller.currentMoveSequence,
        isOurTurn: isOurTurn,
        isWhiteRepertoire: widget.controller.isRepertoireWhite,
        candidateService: _candidateService!,
        boardPreview: widget.boardPreview,
        coherenceResult: widget.coherenceResult,
        currentMoves: widget.controller.currentMoveSequence,
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
              fen: widget.controller.fen,
              label:
                  'Explorer · ${widget.controller.currentMoveSequence.lastOrNull ?? 'start'}',
              reason: 'trap',
            ),
          );
          widget.controller.loadMoveSequence(trap.movesSan);
        },
        onBack: widget.controller.goBack,
        onRoot: widget.controller.goToStart,
        canUndo: widget.controller.writer.canUndo,
        onUndo: _performUndo,
      ),
    );
  }

  Widget _buildTreeContent() {
    if (widget.controller.openingTree == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'No opening tree available',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
      );
    }
    return SizedBox(
      height: 200,
      child: OpeningTreeWidget(
        tree: widget.controller.openingTree!,
        showPgnSearch: false,
        repertoireLines: widget.controller.repertoireLines,
        currentMoveSequence: widget.controller.currentMoveSequence,
        onMoveSelected: (move) {
          widget.controller.userSelectedTreeMove(move);
        },
        onGoBack: () => widget.controller.goBack(),
        onGoForward: () => widget.controller.goForward(),
        onPositionSelected: (fen) {},
      ),
    );
  }
}
