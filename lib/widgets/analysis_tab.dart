/// Browse tab: tree candidates, coverage suggestions, traps, opening tree.
/// Engine + expectimax live on the PGN tab ([PgnWithAnalysisPane]).
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/browse/widgets/browse_panel.dart';
import '../features/coverage/widgets/suggestion_panel.dart';
import '../core/repertoire_controller.dart';
import '../models/build_tree_node.dart';
import '../models/repertoire_line.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/browse/services/candidate_service.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../services/coherence_service.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_suggestion_service.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import '../theme/app_text_styles.dart';
import 'opening_tree_widget.dart';

class AnalysisTab extends StatefulWidget {
  final RepertoireController controller;
  final BuildTree? tree;
  final TreeBuildConfig? treeConfig;
  final FenMap? fenMap;
  final BoardPreviewController boardPreview;
  final CoherenceResult? coherenceResult;
  final bool isGenerating;
  final bool isGenerationPaused;
  final void Function(RepertoireLine line)? onLineSelected;
  final List<TrapLineInfo> traps;
  final CoverageResult? coverageResult;
  final NavigationStack navigationStack;

  const AnalysisTab({
    super.key,
    required this.controller,
    this.tree,
    this.treeConfig,
    this.fenMap,
    required this.boardPreview,
    this.coherenceResult,
    this.isGenerating = false,
    this.isGenerationPaused = false,
    this.onLineSelected,
    this.traps = const [],
    this.coverageResult,
    required this.navigationStack,
  });

  @override
  State<AnalysisTab> createState() => _AnalysisTabState();
}

class _AnalysisTabState extends State<AnalysisTab> {
  bool _showTree = false;

  static const _kTree = 'analysis_tab.show_tree';

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
  void didUpdateWidget(covariant AnalysisTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tree != widget.tree ||
        oldWidget.treeConfig != widget.treeConfig ||
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
        _showTree = prefs.getBool(_kTree) ?? false;
      });
    } catch (e) {
      debugPrint('[AnalysisTab] Failed to load prefs: $e');
    }
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kTree, _showTree);
    } catch (e) {
      debugPrint('[AnalysisTab] Failed to save prefs: $e');
    }
  }

  void _toggleTree() {
    setState(() => _showTree = !_showTree);
    _savePrefs();
  }

  Future<void> _acceptSuggestion(SuggestedLine suggestion) async {
    try {
      await widget.controller.writer.acceptSuggestion(suggestion);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Added ${suggestion.newMoves.join(' ')} to repertoire',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('[AnalysisTab] Failed to accept suggestion: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add suggestion: $e'),
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
    } catch (e) {
      debugPrint('[AnalysisTab] Undo failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Undo failed: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // ── Candidates ────────────────────────────────────────────────────────

  List<CandidateMove> _getCandidates() {
    if (_candidateService == null) return [];
    final isOurTurn =
        widget.controller.position.turn ==
        (widget.controller.isRepertoireWhite ? Side.white : Side.black);
    return _candidateService!.getTreeCandidates(
      fen: widget.controller.fen,
      isOurTurn: isOurTurn,
      playAsWhite: widget.controller.isRepertoireWhite,
      pathFromRoot: widget.controller.currentMoveSequence,
    );
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
      debugPrint('[AnalysisTab] Failed to add move: $e');
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

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final candidates = _getCandidates();
    final isOurTurn =
        widget.controller.position.turn ==
        (widget.controller.isRepertoireWhite ? Side.white : Side.black);

    final hasCandidates = candidates.isNotEmpty;
    final hasBrowseSource =
        widget.tree != null || _candidateService?.coverageService != null;
    final hasSuggestionPanel =
        widget.coverageResult != null && widget.tree != null;
    final hasContent = hasBrowseSource || hasSuggestionPanel || _showTree;

    if (!hasContent) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: const Text(
            'Generate a tree to see candidate moves here.\n'
            'Stockfish and expectimax are on the PGN tab.',
            textAlign: TextAlign.center,
            style: AppTextStyles.muted,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              FilterChip(
                label: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.account_tree, size: 14),
                    SizedBox(width: 4),
                    Text('Opening tree', style: TextStyle(fontSize: 11)),
                  ],
                ),
                selected: _showTree,
                onSelected: (_) => _toggleTree(),
                visualDensity: VisualDensity.compact,
                showCheckmark: false,
              ),
            ],
          ),
        ),
        if (hasSuggestionPanel)
          Expanded(
            flex: hasCandidates ? 2 : 1,
            child: SuggestionPanel(
              service: CoverageSuggestionService(
                coverage: widget.coverageResult!,
                tree: widget.tree,
                fenMap: widget.fenMap,
                coherence: widget.coherenceResult,
              ),
              playAsWhite: widget.controller.isRepertoireWhite,
              boardPreview: widget.boardPreview,
              currentCoverage: widget.coverageResult!.coveragePercent,
              onAccept: _acceptSuggestion,
            ),
          ),
        if (hasBrowseSource && _candidateService != null)
          Expanded(
            flex: hasSuggestionPanel ? 3 : 1,
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
                    tabIndex: 1,
                    fen: widget.controller.fen,
                    label:
                        'PGN · ${widget.controller.currentMoveSequence.lastOrNull ?? 'start'}',
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
          ),
        if (_showTree) ...[
          const Divider(height: 1),
          Expanded(flex: 2, child: _buildTreeSection()),
        ],
      ],
    );
  }

  Widget _buildTreeSection() {
    if (widget.controller.openingTree == null) {
      return const Center(
        child: Text('No opening tree available', style: AppTextStyles.muted),
      );
    }
    return OpeningTreeWidget(
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
      onLineSelected: widget.onLineSelected,
    );
  }
}
