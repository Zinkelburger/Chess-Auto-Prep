/// Analysis tab widget extracted from PGN viewer screen.
///
/// Shows Stockfish full-game analysis: analyze button, eval chart,
/// summary stats, and classified move list with clickable best lines.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/solitaire_trophy.dart';
import '../services/game_analysis_controller.dart';
import '../utils/chess_utils.dart' show formatEvalDisplay;
import 'clickable_move_line.dart';
import 'engine/engine_gate.dart';
import 'game_analysis_chart.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'pgn_viewer_widget.dart';
import '../utils/movetext_builder.dart';

class GameAnalysisTab extends StatefulWidget {
  final GameAnalysisController analysisController;
  final PgnViewerWidgetController pgnController;
  final int currentPly;

  /// Current variation depth (0 = on mainline). Used to update best-line
  /// highlights when the user arrows through a variation.
  final int variationDepth;

  /// PGN text of the game to analyze.
  final String? gamePgnText;

  /// Called with annotated PGN movetext after analysis completes.
  final ValueChanged<String>? onAnnotatedMovetext;

  /// Called when user navigates (e.g. clicks a move, best line, engine line).
  /// Parent should stop auto-play, reclaim focus, etc.
  final VoidCallback? onUserNavigation;

  /// Called after analysis completes so the parent can run trophy detection.
  final Future<void> Function()? onAnalysisComplete;

  /// Trophies detected in this game (for trophy icons on qualifying moves).
  final List<SolitaireTrophy> detectedTrophies;

  const GameAnalysisTab({
    super.key,
    required this.analysisController,
    required this.pgnController,
    required this.currentPly,
    this.variationDepth = 0,
    this.gamePgnText,
    this.onAnnotatedMovetext,
    this.onUserNavigation,
    this.onAnalysisComplete,
    this.detectedTrophies = const [],
  });

  @override
  State<GameAnalysisTab> createState() => _GameAnalysisTabState();
}

class _GameAnalysisTabState extends State<GameAnalysisTab> {
  final ScrollController _moveListScroll = ScrollController();
  final GlobalKey _nearestItemKey = GlobalKey();

  int? _activeBestLinePly;
  int? _activeBestLineMoveIdx;
  int? _activeExpectedMovePly;
  int _prevVariationDepth = 0;

  /// Last classified-move row index we scrolled to; avoids re-scrolling on
  /// every ply step when the same row stays nearest.
  int? _lastAlignedNearestIdx;

  /// Set when navigation was triggered by a tap inside the move list itself.
  /// The user is already pointing at that row, so the list must not scroll
  /// under their cursor; the next alignment pass is skipped once.
  bool _suppressNextAlign = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _alignMoveListToPly(widget.currentPly);
    });
  }

  @override
  void didUpdateWidget(GameAnalysisTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.gamePgnText != oldWidget.gamePgnText) {
      _lastAlignedNearestIdx = null;
    }
    if (widget.currentPly != oldWidget.currentPly) {
      final branchPly = _activeBestLinePly != null
          ? _activeBestLinePly! - 1
          : null;
      final expectedBranchPly = _activeExpectedMovePly != null
          ? _activeExpectedMovePly! - 1
          : null;
      if (widget.currentPly != branchPly &&
          widget.currentPly != expectedBranchPly) {
        _activeBestLinePly = null;
        _activeBestLineMoveIdx = null;
        _activeExpectedMovePly = null;
      }
      _alignMoveListToPly(widget.currentPly);
    }
    // Clear highlight when user exits the variation entirely (back to mainline)
    if (widget.variationDepth == 0 && _prevVariationDepth > 0) {
      _activeBestLinePly = null;
      _activeBestLineMoveIdx = null;
      _activeExpectedMovePly = null;
    }
    _prevVariationDepth = widget.variationDepth;
  }

  /// Classified moves only (inaccuracy and worse, plus interesting).
  static List<MoveEval> _interestingMoves(List<MoveEval> evals) {
    return [
      for (final e in evals)
        if (e.classification != MoveClassification.normal) e,
    ];
  }

  static int _nearestInterestingIndex(List<MoveEval> interesting, int ply) {
    if (interesting.isEmpty) return 0;
    var nearestIdx = 0;
    var nearestDist = (interesting[0].ply - ply).abs();
    for (var i = 1; i < interesting.length; i++) {
      final dist = (interesting[i].ply - ply).abs();
      if (dist < nearestDist) {
        nearestDist = dist;
        nearestIdx = i;
      }
    }
    return nearestIdx;
  }

  void _alignMoveListToPly(int ply) {
    final interesting = _interestingMoves(widget.analysisController.evals);
    if (interesting.isEmpty) return;

    final nearestIdx = _nearestInterestingIndex(interesting, ply);
    if (_suppressNextAlign) {
      _suppressNextAlign = false;
      _lastAlignedNearestIdx = nearestIdx;
      return;
    }
    if (nearestIdx == _lastAlignedNearestIdx) return;
    _lastAlignedNearestIdx = nearestIdx;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _nearestItemKey.currentContext;
      if (ctx == null) return;
      // Scroll only the move list itself — the static Scrollable.ensureVisible
      // would also scroll the enclosing TabBarView and yank the side panel to
      // this tab while the user is on the Game tab (this widget stays alive
      // offstage).
      final renderObject = ctx.findRenderObject();
      final scrollable = Scrollable.maybeOf(ctx);
      if (renderObject == null || scrollable == null) return;
      // Minimal motion: scroll only when the row is outside the viewport,
      // and only far enough to bring it just inside — never recenter, which
      // teleports the list and makes rows jump around. Each policy call
      // no-ops when the row is already visible on that side.
      const duration = Duration(milliseconds: 180);
      const curve = Curves.easeOutCubic;
      unawaited(
        scrollable.position.ensureVisible(
          renderObject,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          duration: duration,
          curve: curve,
        ),
      );
      unawaited(
        scrollable.position.ensureVisible(
          renderObject,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          duration: duration,
          curve: curve,
        ),
      );
    });
  }

  @override
  void dispose() {
    _moveListScroll.dispose();
    super.dispose();
  }

  void _startAnalysis() {
    if (widget.gamePgnText == null) return;
    if (!EngineGate.ensureAvailable(context)) return;
    unawaited(
      widget.analysisController.analyzeGame(
        widget.gamePgnText!,
        onAnnotatedMovetext: widget.onAnnotatedMovetext != null
            ? (annotated) => widget.onAnnotatedMovetext!(annotated)
            : null,
        onComplete: () {
          if (!mounted) return;
          final cb = widget.onAnalysisComplete;
          if (cb != null) unawaited(cb());
        },
      ),
    );
  }

  /// Chart (or any outside-the-list) selection: the row it highlights may be
  /// anywhere, so always scroll it into view — even when it was already the
  /// nearest row (the user may have scrolled the list elsewhere by hand).
  void _onChartPlySelected(int ply) {
    if (ply <= 0) return;
    widget.onUserNavigation?.call();
    _suppressNextAlign = false;
    _lastAlignedNearestIdx = null;
    widget.pgnController.goToMainLineIndex(ply);
  }

  /// Tap on a move card: select without scrolling — the user is already
  /// looking at this row.
  void _onCardTapped(int ply) {
    if (ply <= 0) return;
    widget.onUserNavigation?.call();
    _suppressNextAlign = true;
    widget.pgnController.goToMainLineIndex(ply);
  }

  void _onExpectedMoveClicked(MoveEval eval) {
    if (eval.maiaTopMove == null) return;
    widget.onUserNavigation?.call();
    _suppressNextAlign = true;

    final branchPly = eval.ply - 1;
    if (branchPly < 0) return;
    widget.pgnController.goToMainLineIndex(branchPly);
    widget.pgnController.addEphemeralMove(eval.maiaTopMove!);

    setState(() {
      _activeExpectedMovePly = eval.ply;
      _activeBestLinePly = null;
      _activeBestLineMoveIdx = null;
    });
  }

  void _onBestLineMoveClicked(MoveEval eval, int moveIndex) {
    if (eval.bestLine.isEmpty || moveIndex < 0) return;
    widget.onUserNavigation?.call();
    _suppressNextAlign = true;

    final branchPly = eval.ply - 1;
    if (branchPly < 0) return;
    widget.pgnController.goToMainLineIndex(branchPly);

    for (final san in eval.bestLine) {
      widget.pgnController.addEphemeralMove(san);
    }

    final stepsBack = eval.bestLine.length - 1 - moveIndex;
    for (int i = 0; i < stepsBack; i++) {
      widget.pgnController.goBack();
    }

    setState(() {
      _activeBestLinePly = eval.ply;
      _activeBestLineMoveIdx = moveIndex;
      _activeExpectedMovePly = null;
    });
  }

  String _formatEval(MoveEval e) {
    if (e.deliversCheckmate) return '#';
    return formatEvalDisplay(scoreCp: e.scoreCp, scoreMate: e.scoreMate);
  }

  /// Compute which best-line move to highlight based on variation depth.
  int? _computeBestLineMoveIdx() {
    final depth = widget.variationDepth;
    if (depth <= 0) return _activeBestLineMoveIdx;
    return depth - 1;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.gamePgnText == null) {
      return const Center(
        child: Text(
          'Load a PGN to analyze',
          style: TextStyle(color: AppColors.onSurfaceMuted),
        ),
      );
    }

    final evals = widget.analysisController.evals;
    final isAnalyzing = widget.analysisController.isAnalyzing;
    final total = widget.analysisController.totalMoves;
    final done = widget.analysisController.analyzedMoves;

    return Column(
      children: [
        if (isAnalyzing)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Analyzing move $done / $total  (depth ${widget.analysisController.depth})',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: total > 0 ? done / total : 0,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: widget.analysisController.cancel,
                  icon: const Icon(Icons.stop, size: 20),
                  tooltip: 'Stop analysis',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        if (evals.isNotEmpty) ...[
          GameAnalysisChart(
            evals: evals,
            startWinChance: widget.analysisController.startWinChance,
            currentPly: widget.currentPly,
            onPlySelected: _onChartPlySelected,
          ),
          const Divider(height: 1),
          GameAnalysisSummary(evals: evals),
          const Divider(height: 1),
          Expanded(child: _buildMoveList(evals)),
        ] else if (!isAnalyzing) ...[
          const Spacer(),
          const Icon(Icons.show_chart, size: 48, color: AppColors.onSurfaceDim),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _startAnalysis,
            icon: const Icon(Icons.analytics, size: 20),
            label: const Text('Analyze Game'),
          ),
          const Spacer(),
        ] else
          const Spacer(),
      ],
    );
  }

  Widget _buildMoveList(List<MoveEval> evals) {
    final evalByPly = <int, MoveEval>{};
    for (final e in evals) {
      evalByPly[e.ply] = e;
    }

    final interesting = _interestingMoves(evals);

    // Build a set of plies that have trophies for quick lookup.
    final trophyFens = <String>{};
    for (final t in widget.detectedTrophies) {
      trophyFens.add(t.fen);
    }

    if (interesting.isEmpty && widget.detectedTrophies.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No inaccuracies, mistakes, blunders, or interesting moves found.',
            style: AppTextStyles.muted,
          ),
        ),
      );
    }

    final nearestIdx = _nearestInterestingIndex(interesting, widget.currentPly);

    return ListView(
      controller: _moveListScroll,
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        if (widget.detectedTrophies.isNotEmpty)
          _buildTrophyBanner(widget.detectedTrophies),
        for (var index = 0; index < interesting.length; index++)
          _buildMoveListRow(
            interesting[index],
            index: index,
            nearestIdx: nearestIdx,
            evalByPly: evalByPly,
            hasTrophy: trophyFens.contains(interesting[index].fenBefore),
          ),
      ],
    );
  }

  Widget _buildTrophyBanner(List<SolitaireTrophy> trophies) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.starAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.starAccent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.emoji_events, color: AppColors.starAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              trophies.length == 1
                  ? 'You found a move better than the GM!'
                  : 'You found ${trophies.length} moves better than the GM!',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.starAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMoveListRow(
    MoveEval e, {
    required int index,
    required int nearestIdx,
    required Map<int, MoveEval> evalByPly,
    bool hasTrophy = false,
  }) {
    final numberLabel = moveNumberLabel(
      moveNumber: moveNumberAtPly(e.ply - 1),
      isWhite: e.isWhiteMove,
    );
    final isNearest = index == nearestIdx;

    final Color classColor;
    final String classLabel;
    switch (e.classification) {
      case MoveClassification.blunder:
        classColor = AppColors.moveClassBlunder;
        classLabel = 'Blunder';
      case MoveClassification.mistake:
        classColor = AppColors.moveClassMistake;
        classLabel = 'Mistake';
      case MoveClassification.inaccuracy:
        classColor = AppColors.moveClassInaccuracy;
        classLabel = 'Inaccuracy';
      case MoveClassification.interesting:
        classColor = AppColors.moveClassInteresting;
        classLabel = 'Interesting';
      case MoveClassification.normal:
        classColor = AppColors.onSurfaceMuted;
        classLabel = '';
    }

    final evalStr = _formatEval(e);

    return Container(
      key: isNearest ? _nearestItemKey : null,
      decoration: BoxDecoration(
        color: isNearest ? AppColors.hoverOverlay : null,
        // Always reserve the accent strip (transparent when idle): gaining
        // the highlight must never shift the row's content sideways.
        border: Border(
          left: BorderSide(
            color: isNearest ? classColor : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      child: InkWell(
        onTap: () => _onCardTapped(e.ply),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Text(numberLabel, style: AppTextStyles.caption),
                  ),
                  Text(
                    e.san,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: classColor.withAlpha(30),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: classColor.withAlpha(80)),
                    ),
                    child: Text(
                      classLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: classColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (hasTrophy) ...[
                    const SizedBox(width: 6),
                    const Tooltip(
                      message: 'You found a better move here!',
                      child: Icon(
                        Icons.emoji_events,
                        color: AppColors.starAccent,
                        size: 16,
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    evalStr,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: AppColors.pgnMove,
                    ),
                  ),
                ],
              ),
              if (e.classification == MoveClassification.interesting &&
                  e.maiaProb != null)
                Padding(
                  padding: const EdgeInsets.only(left: 48, top: 3),
                  child: _buildInterestingMoveInfo(e, evalByPly),
                ),
              if (e.bestLine.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 48, top: 3),
                  child: ClickableMoveLineWidget(
                    sanMoves: e.bestLine,
                    startPly: e.ply - 1,
                    activeMoveIndex: _activeBestLinePly == e.ply
                        ? _computeBestLineMoveIdx()
                        : null,
                    onMoveTapped: (idx) => _onBestLineMoveClicked(e, idx),
                    label: 'Best: ',
                    fontSize: 14,
                    movePadding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 4,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInterestingMoveInfo(MoveEval e, Map<int, MoveEval> evalByPly) {
    final prevEval = evalByPly[e.ply - 1];
    final playedEval = _formatEval(e);
    final bestEval = prevEval != null ? _formatEval(prevEval) : null;

    const monoStyle = TextStyle(fontSize: 11, fontFamily: 'monospace');

    final spans = <InlineSpan>[
      TextSpan(
        text: '${e.san} ',
        style: monoStyle.copyWith(
          color: AppColors.maia,
          fontWeight: FontWeight.bold,
        ),
      ),
      TextSpan(
        text: '$playedEval ',
        style: monoStyle.copyWith(color: AppColors.pgnMove),
      ),
      TextSpan(
        text: '${(e.maiaProb! * 100).toStringAsFixed(0)}% likely',
        style: monoStyle.copyWith(color: AppColors.pgnMove),
      ),
    ];

    if (e.maiaTopMove != null &&
        e.maiaTopProb != null &&
        e.maiaTopMove != e.san) {
      final isExpectedActive = _activeExpectedMovePly == e.ply;
      spans.addAll([
        TextSpan(
          text: '  ·  ',
          style: monoStyle.copyWith(color: AppColors.onSurfaceMuted),
        ),
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => _onExpectedMoveClicked(e),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: isExpectedActive
                    ? BoxDecoration(
                        color: AppColors.pgnMoveCurrentBg,
                        borderRadius: BorderRadius.circular(2),
                      )
                    : null,
                child: Text(
                  e.maiaTopMove!,
                  style: monoStyle.copyWith(
                    color: isExpectedActive
                        ? AppColors.pgnMoveCurrentFg
                        : AppColors.pgnMainLine,
                    fontWeight: FontWeight.bold,
                    decoration: isExpectedActive
                        ? null
                        : TextDecoration.underline,
                    decorationColor: AppColors.pgnMainLine.withValues(
                      alpha: 0.31,
                    ),
                    decorationStyle: TextDecorationStyle.dotted,
                  ),
                ),
              ),
            ),
          ),
        ),
        const TextSpan(text: ' '),
        if (bestEval != null)
          TextSpan(
            text: '$bestEval ',
            style: monoStyle.copyWith(color: AppColors.pgnMove),
          ),
        TextSpan(
          text: '${(e.maiaTopProb! * 100).toStringAsFixed(0)}% expected',
          style: monoStyle.copyWith(color: AppColors.pgnMove),
        ),
      ]);
    }

    return RichText(text: TextSpan(children: spans));
  }
}
