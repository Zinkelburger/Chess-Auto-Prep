/// Browse tab: tree candidates, coverage suggestions, traps, opening tree.
/// Engine + expectimax live on the PGN tab ([PgnWithAnalysisPane]).
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/repertoire_controller.dart';
import '../models/build_tree_node.dart';
import '../models/repertoire_line.dart';
import '../models/trap_line_info.dart';
import '../services/board_preview_controller.dart';
import '../services/candidate_service.dart';
import '../services/coherence_service.dart';
import '../services/coverage_service.dart';
import '../services/coverage_suggestion_service.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/navigation_stack.dart';
import '../services/trap_index_service.dart';
import '../theme/app_colors.dart';
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
  final void Function(List<String> moves, String title, String pgn)?
      onLineSaved;

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
    this.onLineSaved,
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
        oldWidget.fenMap != widget.fenMap) {
      _rebuildCandidateService();
    }
    if (oldWidget.traps != widget.traps) {
      _rebuildTrapIndex();
    }
  }

  void _rebuildTrapIndex() {
    _trapIndexCache =
        widget.traps.isEmpty ? null : TrapIndexService(widget.traps);
  }

  void _rebuildCandidateService() {
    _candidateService = CandidateService(
      tree: widget.tree,
      fenMap: widget.fenMap,
    );
  }

  void _onControllerChanged() {
    _expandedTrapIndex = null;
    if (mounted) setState(() {});
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

  // ── Suggested lines ──────────────────────────────────────────────────

  List<SuggestedLine> _getSuggestedLines() {
    if (widget.coverageResult == null || widget.tree == null) return [];
    final service = CoverageSuggestionService(
      coverage: widget.coverageResult!,
      tree: widget.tree,
      fenMap: widget.fenMap,
    );
    return service.generateSuggestions(
      targetCoverage: widget.coverageResult!.coveragePercent + 10,
      playAsWhite: widget.controller.isRepertoireWhite,
      maxSuggestions: 3,
    );
  }

  // ── Candidates ────────────────────────────────────────────────────────

  List<CandidateMove> _getCandidates() {
    if (_candidateService == null) return [];
    final isOurTurn = widget.controller.position.turn ==
        (widget.controller.isRepertoireWhite ? Side.white : Side.black);
    return _candidateService!.getTreeCandidates(
      fen: widget.controller.fen,
      isOurTurn: isOurTurn,
      playAsWhite: widget.controller.isRepertoireWhite,
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final suggestedLines = _getSuggestedLines();
    final candidates = _getCandidates();
    final isOurTurn = widget.controller.position.turn ==
        (widget.controller.isRepertoireWhite ? Side.white : Side.black);

    final hasCandidates = candidates.isNotEmpty;
    final hasSuggestions = suggestedLines.isNotEmpty;
    final hasContent = hasCandidates || hasSuggestions || _showTree;

    if (!hasContent) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Generate a tree to see candidate moves here.\n'
            'Stockfish and expectimax are on the PGN tab.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
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
        if (hasSuggestions)
          _SuggestedLinesSection(
            suggestions: suggestedLines,
            boardPreview: widget.boardPreview,
            navigationStack: widget.navigationStack,
            onAccept: (suggestion) {
              widget.onLineSaved?.call(
                suggestion.fullMoves,
                'Suggested: +${suggestion.coverageGain.toStringAsFixed(1)}%',
                suggestion.fullMoves.join(' '),
              );
            },
          ),
        if (hasCandidates)
          Expanded(
            flex: hasSuggestions ? 3 : 1,
            child: _CandidatesSection(
              candidates: candidates,
              isOurTurn: isOurTurn,
              boardPreview: widget.boardPreview,
              trapIndex: _trapIndexCache,
              expandedTrapIndex: _expandedTrapIndex,
              navigationStack: widget.navigationStack,
              onCandidateTap: (move) {
                widget.controller.userPlayedMove(move.san);
              },
              onExpandTraps: (idx) {
                setState(() {
                  _expandedTrapIndex =
                      _expandedTrapIndex == idx ? null : idx;
                });
              },
              onTrapGo: (trap) {
                widget.navigationStack.push(NavigationEntry(
                  tabIndex: 1,
                  fen: widget.controller.fen,
                  label:
                      'PGN · ${widget.controller.currentMoveSequence.lastOrNull ?? 'start'}',
                  reason: 'trap',
                ));
                widget.controller.loadMoveSequence(trap.movesSan);
              },
            ),
          ),
        if (_showTree) ...[
          const Divider(height: 1),
          Expanded(
            flex: 2,
            child: _buildTreeSection(),
          ),
        ],
      ],
    );
  }

  Widget _buildTreeSection() {
    if (widget.controller.openingTree == null) {
      return const Center(
        child: Text('No opening tree available',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
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

// ── Suggested Lines Section ──────────────────────────────────────────────

class _SuggestedLinesSection extends StatelessWidget {
  final List<SuggestedLine> suggestions;
  final BoardPreviewController boardPreview;
  final NavigationStack navigationStack;
  final void Function(SuggestedLine) onAccept;

  const _SuggestedLinesSection({
    required this.suggestions,
    required this.boardPreview,
    required this.navigationStack,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.lightbulb_outline,
                    size: 14, color: AppColors.evalPositive),
                const SizedBox(width: 6),
                Text(
                  'SUGGESTED LINES',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[400],
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: suggestions.length,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemBuilder: (ctx, i) {
                final s = suggestions[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      '+${s.coverageGain.toStringAsFixed(1)}% coverage',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.green,
                                      ),
                                    ),
                                    if (s.linePlayability != null) ...[
                                      const SizedBox(width: 8),
                                      Text(
                                        'quality ${s.linePlayability!.toStringAsFixed(2)}',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey[500],
                                        ),
                                      ),
                                    ],
                                    if (s.trapCount > 0) ...[
                                      const SizedBox(width: 8),
                                      Icon(Icons.bolt,
                                          size: 10,
                                          color: AppColors.warning),
                                      Text(
                                        '${s.trapCount}',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: AppColors.warning,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  s.fullMoves.join(' '),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () => onAccept(s),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('+ Add',
                                style: TextStyle(fontSize: 11)),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

// ── Candidates Section ──────────────────────────────────────────────────

class _CandidatesSection extends StatelessWidget {
  final List<CandidateMove> candidates;
  final bool isOurTurn;
  final BoardPreviewController boardPreview;
  final TrapIndexService? trapIndex;
  final int? expandedTrapIndex;
  final NavigationStack navigationStack;
  final void Function(CandidateMove) onCandidateTap;
  final void Function(int) onExpandTraps;
  final void Function(TrapLineInfo) onTrapGo;

  const _CandidatesSection({
    required this.candidates,
    required this.isOurTurn,
    required this.boardPreview,
    required this.trapIndex,
    required this.expandedTrapIndex,
    required this.navigationStack,
    required this.onCandidateTap,
    required this.onExpandTraps,
    required this.onTrapGo,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Icon(
                isOurTurn ? Icons.person : Icons.people,
                size: 14,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                isOurTurn ? 'YOUR RESPONSE' : 'OPPONENT MOVES',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey[400],
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              Text(
                '${candidates.length} moves',
                style: TextStyle(fontSize: 10, color: Colors.grey[500]),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: candidates.length,
            itemBuilder: (ctx, i) {
              final c = candidates[i];
              final trapCount = c.subtreeTrapCount ?? 0;
              final isExpanded = expandedTrapIndex == i;

              return Column(
                children: [
                  _CandidateRowWithTraps(
                    candidate: c,
                    isOurTurn: isOurTurn,
                    trapCount: trapCount,
                    isExpanded: isExpanded,
                    onTap: () => onCandidateTap(c),
                    onExpandTraps: trapCount > 0
                        ? () => onExpandTraps(i)
                        : null,
                    boardPreview: boardPreview,
                  ),
                  if (isExpanded && trapCount > 0)
                    _ExpandedTrapList(
                      candidate: c,
                      trapIndex: trapIndex,
                      onTrapGo: onTrapGo,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CandidateRowWithTraps extends StatefulWidget {
  final CandidateMove candidate;
  final bool isOurTurn;
  final int trapCount;
  final bool isExpanded;
  final VoidCallback onTap;
  final VoidCallback? onExpandTraps;
  final BoardPreviewController boardPreview;

  const _CandidateRowWithTraps({
    required this.candidate,
    required this.isOurTurn,
    required this.trapCount,
    required this.isExpanded,
    required this.onTap,
    this.onExpandTraps,
    required this.boardPreview,
  });

  @override
  State<_CandidateRowWithTraps> createState() =>
      _CandidateRowWithTrapsState();
}

class _CandidateRowWithTrapsState extends State<_CandidateRowWithTraps> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.candidate;
    final theme = Theme.of(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _isHovered
                ? theme.colorScheme.surfaceContainerHighest
                : null,
            border: Border(
              left: BorderSide(
                width: 3,
                color: c.isRepertoireMove == true
                    ? Colors.green
                    : widget.trapCount > 0
                        ? AppColors.warning
                        : Colors.transparent,
              ),
            ),
          ),
          child: Row(
            children: [
              if (c.isRepertoireMove == true)
                const Icon(Icons.star, size: 14, color: Colors.amber)
              else
                const SizedBox(width: 14),
              const SizedBox(width: 8),
              Text(
                c.san,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (c.evalCp != null) ...[
                _evalChip(c.evalCp!),
                const SizedBox(width: 6),
              ],
              if (c.myEase != null && widget.isOurTurn) ...[
                Text(
                  c.myEase!.toStringAsFixed(2),
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.lichessDb,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 6),
              ],
              if (!widget.isOurTurn && c.dbFrequency != null) ...[
                Text(
                  '${(c.dbFrequency! * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 11),
                ),
                const SizedBox(width: 6),
              ],
              if (widget.trapCount > 0)
                InkWell(
                  onTap: widget.onExpandTraps,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bolt,
                            size: 10, color: AppColors.warning),
                        Text(
                          '${widget.trapCount}',
                          style: TextStyle(
                              fontSize: 10, color: AppColors.warning),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          widget.isExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 12,
                          color: AppColors.warning,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _evalChip(int cp) {
    final pawns = cp / 100.0;
    final text = '${pawns >= 0 ? "+" : ""}${pawns.toStringAsFixed(2)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: cp >= 0 ? Colors.green.withAlpha(25) : Colors.red.withAlpha(25),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: cp >= 0 ? Colors.green : Colors.red,
          )),
    );
  }
}

class _ExpandedTrapList extends StatefulWidget {
  final CandidateMove candidate;
  final TrapIndexService? trapIndex;
  final void Function(TrapLineInfo) onTrapGo;

  const _ExpandedTrapList({
    required this.candidate,
    required this.trapIndex,
    required this.onTrapGo,
  });

  @override
  State<_ExpandedTrapList> createState() => _ExpandedTrapListState();
}

class _ExpandedTrapListState extends State<_ExpandedTrapList> {
  int _currentTrapIdx = 0;

  List<TrapLineInfo> get _traps {
    if (widget.trapIndex == null || widget.candidate.treeNode == null) {
      return [];
    }
    final node = widget.candidate.treeNode!;
    final movePath = <String>[];
    var current = node;
    while (current.parent != null) {
      movePath.insert(0, current.moveSan);
      current = current.parent!;
    }
    return widget.trapIndex!.trapsInLine(movePath);
  }

  @override
  Widget build(BuildContext context) {
    final traps = _traps;
    if (traps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
        child: Text(
          'No trap details available',
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.04),
        border: const Border(
          left: BorderSide(width: 2, color: AppColors.warning),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < traps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text(
                    i < traps.length - 1 ? '├' : '└',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${traps[i].popularMove}? played ${(traps[i].popularProb * 100).toStringAsFixed(0)}%, '
                      'loses ${(traps[i].evalDiffCp / 100).toStringAsFixed(1)} pawns',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  InkWell(
                    onTap: () => widget.onTrapGo(traps[i]),
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey.withAlpha(80)),
                      ),
                      child: const Text('Go',
                          style: TextStyle(fontSize: 10)),
                    ),
                  ),
                ],
              ),
            ),
          if (traps.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _currentTrapIdx > 0
                        ? () {
                            setState(() => _currentTrapIdx--);
                            widget.onTrapGo(traps[_currentTrapIdx]);
                          }
                        : null,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Prev',
                        style: TextStyle(fontSize: 10)),
                  ),
                  TextButton(
                    onPressed: _currentTrapIdx < traps.length - 1
                        ? () {
                            setState(() => _currentTrapIdx++);
                            widget.onTrapGo(traps[_currentTrapIdx]);
                          }
                        : null,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Next',
                        style: TextStyle(fontSize: 10)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
