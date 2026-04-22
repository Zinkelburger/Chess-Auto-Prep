import 'package:flutter/material.dart';

import '../../../utils/ease_utils.dart' show winProbability;
import '../../../utils/tree_colors.dart';
import '../controllers/eval_tree_controller.dart';
import '../models/eval_tree_snapshot.dart';

class EvalTreeDetailsPane extends StatelessWidget {
  final EvalTreeSnapshot snapshot;
  final EvalTreeController controller;
  final EvalTreeNodeSnapshot currentNode;

  const EvalTreeDetailsPane({
    super.key,
    required this.snapshot,
    required this.controller,
    required this.currentNode,
  });

  @override
  Widget build(BuildContext context) {
    final children = snapshot.childrenOf(currentNode.id);
    final isOurTurn = currentNode.sideToMoveIsWhite == snapshot.playAsWhite;
    final showCplForChildren =
        controller.metricDisplayMode == EvalTreeMetricDisplayMode.cpl &&
            isOurTurn;

    double maxProb = 0;
    for (final child in children) {
      if (child.moveProbability > maxProb) {
        maxProb = child.moveProbability;
      }
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildHeader(isOurTurn)),
        SliverToBoxAdapter(child: _buildStatsPanel(context)),
        SliverToBoxAdapter(child: _buildWinProbBar()),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        SliverToBoxAdapter(
          child: _buildChildrenLabel(children.length, isOurTurn),
        ),
        if (children.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildLeafMessage(),
          )
        else
          SliverList.builder(
            itemCount: children.length,
            itemBuilder: (context, index) =>
                _buildChildItem(children[index], maxProb, showCplForChildren),
          ),
      ],
    );
  }

  Widget _buildHeader(bool isOurTurn) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(
          bottom: BorderSide(color: Colors.grey[700]!, width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: roleBadgeColor(isOurTurn),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              isOurTurn ? 'Our move' : 'Opponent',
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _movePath(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[300],
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              icon: Icon(Icons.arrow_back, size: 18, color: Colors.grey[400]),
              padding: EdgeInsets.zero,
              tooltip: 'Back',
              onPressed:
                  currentNode.parentId != null ? controller.goParent : null,
            ),
          ),
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              icon:
                  Icon(Icons.arrow_forward, size: 18, color: Colors.grey[400]),
              padding: EdgeInsets.zero,
              tooltip: 'Forward',
              onPressed: currentNode.childIds.isNotEmpty
                  ? controller.goPreferredChild
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsPanel(BuildContext context) {
    final evalCp = currentNode.evalForUsCp;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              if (evalCp != null)
                _statBadge('Eval', _formatEval(evalCp), evalColor(evalCp)),
              _statBadge(
                'Reach',
                '${(currentNode.cumulativeProbability * 100).toStringAsFixed(2)}%',
                Colors.blue[300]!,
              ),
              if (currentNode.ease != null)
                _statBadge(
                  'Ease',
                  currentNode.ease!.toStringAsFixed(3),
                  easeColor(currentNode.ease!),
                ),
            ],
          ),
          if (currentNode.expectimaxValue != null ||
              currentNode.totalGames > 0) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                if (currentNode.expectimaxValue != null)
                  _statBadge(
                    'Local CPL',
                    '${(currentNode.localCpl ?? 0).toStringAsFixed(1)} cpl',
                    cplColor(currentNode.localCpl ?? 0),
                  ),
                if (currentNode.expectimaxValue != null)
                  _statBadge(
                    'V',
                    '${(currentNode.expectimaxValue! * 100).toStringAsFixed(1)}%',
                    vColor(currentNode.expectimaxValue!),
                  ),
                if (currentNode.totalGames > 0)
                  _statBadge(
                      'Games', '${currentNode.totalGames}', Colors.grey[400]!),
              ],
            ),
          ],
          if (currentNode.subtreePly > 0 ||
              currentNode.pruneKind != EvalTreePruneKind.none ||
              (currentNode.trapScore ?? 0) > 0.05) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                if (currentNode.subtreePly > 0)
                  _statBadge(
                    'Subtree',
                    '${currentNode.subtreePly} ply',
                    Colors.grey[400]!,
                  ),
                if ((currentNode.trapScore ?? 0) > 0.05)
                  _statBadge(
                    'Trap',
                    '${((currentNode.trapScore ?? 0) * 100).toStringAsFixed(0)}%',
                    trapColor(currentNode.trapScore ?? 0),
                  ),
                if (currentNode.pruneKind != EvalTreePruneKind.none)
                  _pruneBadge(),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWinProbBar() {
    final evalCp = currentNode.evalForUsCp;
    if (evalCp == null) {
      return const SizedBox.shrink();
    }

    final winProb = winProbability(evalCp);
    return Container(
      height: 10,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Colors.grey[700]!, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Row(
          children: [
            Expanded(
              flex: (winProb * 1000).round().clamp(1, 999),
              child: Container(color: Colors.white),
            ),
            Expanded(
              flex: ((1 - winProb) * 1000).round().clamp(1, 999),
              child: Container(color: Colors.grey[900]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChildrenLabel(int count, bool isOurTurn) {
    if (count == 0) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Text(
            isOurTurn ? 'Candidate moves' : 'Opponent replies',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.grey[400],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '($count)',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildChildItem(
    EvalTreeNodeSnapshot child,
    double maxProb,
    bool showCplMetric,
  ) {
    final evalCp = child.evalForUsCp;
    final localCpl = child.localCpl;
    final barFraction = maxProb > 0 ? child.moveProbability / maxProb : 0.0;
    final isRepertoire = child.isRepertoireMove;

    return InkWell(
      onTap: () => controller.selectNode(child.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color:
              isRepertoire ? kNodeColorOurMove.withValues(alpha: 0.14) : null,
          border: Border(
            bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
            left: isRepertoire
                ? BorderSide(color: kNodeAccentRepertoire, width: 3)
                : BorderSide.none,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isRepertoire)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.star, size: 14, color: Colors.amber[400]),
                  ),
                SizedBox(
                  width: 64,
                  child: Text(
                    child.moveSan,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (showCplMetric && localCpl != null)
                  _buildCplBadge(localCpl)
                else if (evalCp != null)
                  _buildEvalBadge(evalCp),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${(child.moveProbability * 100).toStringAsFixed(1)}%',
                    style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                  ),
                ),
                if (child.expectimaxValue != null)
                  Text(
                    'V ${(child.expectimaxValue! * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: vColor(child.expectimaxValue!),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                SizedBox(
                  width: 64,
                  child: _buildProbabilityBar(barFraction),
                ),
                const SizedBox(width: 8),
                if (child.ease != null)
                  _miniStat(
                    'ease',
                    child.ease!.toStringAsFixed(2),
                    easeColor(child.ease!),
                  ),
                if (child.totalGames > 0)
                  _miniStat(
                    'games',
                    _compactNumber(child.totalGames),
                    Colors.grey[500]!,
                  ),
                if ((child.trapScore ?? 0) > 0.05)
                  _miniStat(
                    'trap',
                    '${((child.trapScore ?? 0) * 100).toStringAsFixed(0)}%',
                    trapColor(child.trapScore ?? 0),
                  ),
                if (isRepertoire && child.repertoireScore != 0)
                  _miniStat(
                    'score',
                    child.repertoireScore.toStringAsFixed(2),
                    Colors.amber[300]!,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEvalBadge(int evalCp) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: evalBgColor(evalCp),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _formatEval(evalCp),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: evalTextColor(evalCp),
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  Widget _buildCplBadge(double localCpl) {
    final accentColor = cplColor(localCpl);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: accentColor.withValues(alpha: 0.45)),
      ),
      child: Text(
        '${localCpl.toStringAsFixed(0)}cpl',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: accentColor,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  Widget _buildLeafMessage() {
    String message;
    switch (currentNode.pruneKind) {
      case EvalTreePruneKind.evalTooHigh:
        message = 'Position is already winning, no further preparation needed.';
        break;
      case EvalTreePruneKind.evalTooLow:
        message = 'Position is too bad, pruned from the repertoire.';
        break;
      case EvalTreePruneKind.none:
        message = 'Leaf node, no further moves explored.';
        break;
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.park, size: 32, color: Colors.grey[600]),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statBadge(String label, String value, Color valueColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            color: valueColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _pruneBadge() {
    final isHigh = currentNode.pruneKind == EvalTreePruneKind.evalTooHigh;
    final evalStr = currentNode.pruneEvalCp != null
        ? ' (${_formatEval(currentNode.pruneEvalCp!)})'
        : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isHigh ? Colors.green[900] : Colors.red[900],
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isHigh ? 'Winning$evalStr' : 'Lost$evalStr',
        style: const TextStyle(fontSize: 10, color: Colors.white),
      ),
    );
  }

  Widget _miniStat(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Text(
        '$label:$value',
        style: TextStyle(fontSize: 10, color: color, fontFamily: 'monospace'),
      ),
    );
  }

  Widget _buildProbabilityBar(double fraction) {
    return SizedBox(
      height: 6,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              color: Colors.grey[800],
            ),
          ),
          FractionallySizedBox(
            widthFactor: fraction.clamp(0.02, 1.0),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: Colors.blue[400],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _movePath() {
    final moves = snapshot.movePathSan(currentNode.id);
    if (moves.isEmpty) {
      return 'Starting position';
    }
    final buffer = StringBuffer();
    final whiteFirst = snapshot.root.sideToMoveIsWhite;
    for (var index = 0; index < moves.length; index++) {
      final ply = index + (whiteFirst ? 0 : 1);
      if (ply.isEven) {
        buffer.write('${(ply ~/ 2) + 1}. ');
      } else if (index == 0 && !whiteFirst) {
        buffer.write('${(ply ~/ 2) + 1}... ');
      }
      buffer.write('${moves[index]} ');
    }
    return buffer.toString().trim();
  }

  String _formatEval(int cpForUs) {
    if (cpForUs.abs() >= 10000) {
      return cpForUs > 0 ? '+M' : '-M';
    }
    final pawns = cpForUs / 100.0;
    return '${pawns >= 0 ? "+" : ""}${pawns.toStringAsFixed(2)}';
  }

  String _compactNumber(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}
