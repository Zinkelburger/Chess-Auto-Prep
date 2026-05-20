/// Analysis tab widget extracted from PGN viewer screen.
///
/// Shows Stockfish full-game analysis: analyze button, eval chart,
/// summary stats, and classified move list with clickable best lines.
library;

import 'package:flutter/material.dart';

import '../services/game_analysis_controller.dart';
import '../utils/chess_utils.dart' show formatEvalDisplay;
import '../widgets/clickable_move_line.dart';
import '../widgets/game_analysis_chart.dart';
import '../widgets/pgn_viewer_widget.dart';

class GameAnalysisTab extends StatefulWidget {
  final GameAnalysisController analysisController;
  final PgnViewerController pgnController;
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

  const GameAnalysisTab({
    super.key,
    required this.analysisController,
    required this.pgnController,
    required this.currentPly,
    this.variationDepth = 0,
    this.gamePgnText,
    this.onAnnotatedMovetext,
    this.onUserNavigation,
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

  @override
  void didUpdateWidget(GameAnalysisTab oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    }
    // Clear highlight when user exits the variation entirely (back to mainline)
    if (widget.variationDepth == 0 && _prevVariationDepth > 0) {
      _activeBestLinePly = null;
      _activeBestLineMoveIdx = null;
      _activeExpectedMovePly = null;
    }
    _prevVariationDepth = widget.variationDepth;
  }

  @override
  void dispose() {
    _moveListScroll.dispose();
    super.dispose();
  }

  void _startAnalysis() {
    if (widget.gamePgnText == null) return;
    widget.analysisController.analyzeGame(
      widget.gamePgnText!,
      onAnnotatedMovetext: widget.onAnnotatedMovetext != null
          ? (annotated) => widget.onAnnotatedMovetext!(annotated)
          : null,
    );
  }

  void _onPlySelected(int ply) {
    if (ply <= 0) return;
    widget.onUserNavigation?.call();
    widget.pgnController.clearEphemeralMoves();
    widget.pgnController.goToMainLineIndex(ply);
  }

  void _onExpectedMoveClicked(MoveEval eval) {
    if (eval.maiaTopMove == null) return;
    widget.onUserNavigation?.call();

    final branchPly = eval.ply - 1;
    if (branchPly < 0) return;
    widget.pgnController.clearEphemeralMoves();
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

    final branchPly = eval.ply - 1;
    if (branchPly < 0) return;
    widget.pgnController.clearEphemeralMoves();
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

  String _formatEval(MoveEval e) =>
      formatEvalDisplay(scoreCp: e.scoreCp, scoreMate: e.scoreMate);

  /// Compute which best-line move to highlight based on variation depth.
  int? _computeBestLineMoveIdx() {
    final depth = widget.variationDepth;
    if (depth <= 0) return _activeBestLineMoveIdx;
    return depth - 1;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.gamePgnText == null) {
      return Center(
        child: Text(
          'Load a PGN to analyze',
          style: TextStyle(color: Colors.grey[500]),
        ),
      );
    }

    final evals = widget.analysisController.evals;
    final isAnalyzing = widget.analysisController.isAnalyzing;
    final total = widget.analysisController.totalMoves;
    final done = widget.analysisController.analyzedMoves;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              if (!isAnalyzing)
                FilledButton.icon(
                  onPressed: _startAnalysis,
                  icon: const Icon(Icons.analytics, size: 18),
                  label: Text(evals.isEmpty ? 'Analyze Game' : 'Re-analyze'),
                )
              else ...[
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
              if (!isAnalyzing && evals.isNotEmpty) ...[
                const Spacer(),
                _buildDepthSelector(),
              ],
            ],
          ),
        ),
        if (evals.isNotEmpty) ...[
          GameAnalysisChart(
            evals: evals,
            startWinChance: widget.analysisController.startWinChance,
            currentPly: widget.currentPly,
            onPlySelected: _onPlySelected,
          ),
          const Divider(height: 1),
          GameAnalysisSummary(evals: evals),
          const Divider(height: 1),
          Expanded(child: _buildMoveList(evals)),
        ] else if (!isAnalyzing) ...[
          const Spacer(),
          Icon(Icons.show_chart, size: 48, color: Colors.grey[700]),
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

  Widget _buildDepthSelector() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Depth:',
            style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        const SizedBox(width: 4),
        PopupMenuButton<int>(
          tooltip: 'Analysis depth',
          onSelected: (d) =>
              setState(() => widget.analysisController.depth = d),
          itemBuilder: (ctx) => [
            for (final d in [10, 12, 14, 16, 18, 20, 22, 24])
              PopupMenuItem(
                value: d,
                child: Row(
                  children: [
                    if (d == widget.analysisController.depth)
                      const Icon(Icons.check, size: 16)
                    else
                      const SizedBox(width: 16),
                    const SizedBox(width: 8),
                    Text('$d'),
                  ],
                ),
              ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.grey[700]!),
            ),
            child: Text(
              '${widget.analysisController.depth}',
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMoveList(List<MoveEval> evals) {
    final evalByPly = <int, MoveEval>{};
    for (final e in evals) {
      evalByPly[e.ply] = e;
    }

    final interesting = <MoveEval>[];
    for (final e in evals) {
      if (e.classification != MoveClassification.normal) {
        interesting.add(e);
      }
    }

    if (interesting.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No inaccuracies, mistakes, blunders, or interesting moves found.',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ),
      );
    }

    final ply = widget.currentPly;
    int nearestIdx = 0;
    int nearestDist = (interesting[0].ply - ply).abs();
    for (int i = 1; i < interesting.length; i++) {
      final dist = (interesting[i].ply - ply).abs();
      if (dist < nearestDist) {
        nearestDist = dist;
        nearestIdx = i;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_moveListScroll.hasClients) return;
      // Rough scroll first so ListView.builder materialises the target item.
      const estimatedItemHeight = 60.0;
      final roughOffset = (nearestIdx * estimatedItemHeight) -
          (_moveListScroll.position.viewportDimension / 2) +
          (estimatedItemHeight / 2);
      final clamped = roughOffset.clamp(
        0.0,
        _moveListScroll.position.maxScrollExtent,
      );
      _moveListScroll.jumpTo(clamped);

      // Now the keyed widget should be built; fine-tune with ensureVisible.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _nearestItemKey.currentContext;
        if (ctx == null) return;
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    });

    return ListView.builder(
      controller: _moveListScroll,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: interesting.length,
      itemBuilder: (context, index) {
        final e = interesting[index];
        final moveNum = (e.ply + 1) ~/ 2;
        final dots = e.isWhiteMove ? '.' : '...';
        final isNearest = index == nearestIdx;

        final Color classColor;
        final String classLabel;
        switch (e.classification) {
          case MoveClassification.blunder:
            classColor = const Color(0xFFDB3B21);
            classLabel = 'Blunder';
          case MoveClassification.mistake:
            classColor = const Color(0xFFE69F00);
            classLabel = 'Mistake';
          case MoveClassification.inaccuracy:
            classColor = const Color(0xFF56B4E9);
            classLabel = 'Inaccuracy';
          case MoveClassification.interesting:
            classColor = const Color(0xFF9C27B0);
            classLabel = 'Interesting';
          case MoveClassification.normal:
            classColor = Colors.grey;
            classLabel = '';
        }

        final evalStr = _formatEval(e);

        return GestureDetector(
          key: isNearest ? _nearestItemKey : null,
          behavior: HitTestBehavior.translucent,
          onTap: () => _onPlySelected(e.ply),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: isNearest
                ? BoxDecoration(
                    color: Colors.white.withAlpha(12),
                    border: Border(
                      left: BorderSide(color: classColor, width: 3),
                    ),
                  )
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 48,
                      child: Text(
                        '$moveNum$dots',
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
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
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: classColor.withAlpha(30),
                        borderRadius: BorderRadius.circular(4),
                        border:
                            Border.all(color: classColor.withAlpha(80)),
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
                    const Spacer(),
                    Text(
                      evalStr,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.grey[400],
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
                      onMoveTapped: (idx) =>
                          _onBestLineMoveClicked(e, idx),
                      label: 'Best: ',
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInterestingMoveInfo(
      MoveEval e, Map<int, MoveEval> evalByPly) {
    final prevEval = evalByPly[e.ply - 1];
    final playedEval = _formatEval(e);
    final bestEval = prevEval != null ? _formatEval(prevEval) : null;

    const monoStyle = TextStyle(fontSize: 11, fontFamily: 'monospace');

    final spans = <InlineSpan>[
      TextSpan(
        text: '${e.san} ',
        style: monoStyle.copyWith(
            color: Colors.purple[300], fontWeight: FontWeight.bold),
      ),
      TextSpan(
        text: '$playedEval ',
        style: monoStyle.copyWith(color: Colors.grey[400]),
      ),
      TextSpan(
        text: '${(e.maiaProb! * 100).toStringAsFixed(0)}% likely',
        style: monoStyle.copyWith(color: Colors.grey[500]),
      ),
    ];

    if (e.maiaTopMove != null &&
        e.maiaTopProb != null &&
        e.maiaTopMove != e.san) {
      final isExpectedActive = _activeExpectedMovePly == e.ply;
      spans.addAll([
        TextSpan(
            text: '  ·  ',
            style: monoStyle.copyWith(color: Colors.grey[600])),
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
                        color: Colors.teal[700],
                        borderRadius: BorderRadius.circular(2),
                      )
                    : null,
                child: Text(
                  e.maiaTopMove!,
                  style: monoStyle.copyWith(
                    color:
                        isExpectedActive ? Colors.white : Colors.teal[300],
                    fontWeight: FontWeight.bold,
                    decoration: isExpectedActive
                        ? null
                        : TextDecoration.underline,
                    decorationColor: Colors.teal[300]!.withAlpha(80),
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
            style: monoStyle.copyWith(color: Colors.grey[400]),
          ),
        TextSpan(
          text: '${(e.maiaTopProb! * 100).toStringAsFixed(0)}% expected',
          style: monoStyle.copyWith(color: Colors.grey[500]),
        ),
      ]);
    }

    return RichText(text: TextSpan(children: spans));
  }
}
