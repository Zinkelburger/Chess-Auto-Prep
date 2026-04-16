/// Interactive tree viewer for [BuildTree] / expectimax analysis.
///
/// Displays engine eval, probability, local CPL (opponent expected
/// centipawn loss), expectimax value, ease, and other metrics for each
/// node.  Allows the user to traverse the tree manually.
library;

import 'package:flutter/material.dart';

import '../models/build_tree_node.dart';
import '../utils/ease_utils.dart' show winProbability;

class BuildTreeWidget extends StatefulWidget {
  final BuildTree tree;
  final bool playAsWhite;
  final Function(String fen)? onPositionSelected;

  const BuildTreeWidget({
    super.key,
    required this.tree,
    required this.playAsWhite,
    this.onPositionSelected,
  });

  @override
  State<BuildTreeWidget> createState() => BuildTreeWidgetState();
}

class BuildTreeWidgetState extends State<BuildTreeWidget> {
  late BuildTreeNode _currentNode;

  @override
  void initState() {
    super.initState();
    _currentNode = widget.tree.root;
  }

  @override
  void didUpdateWidget(BuildTreeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tree != widget.tree) {
      _currentNode = widget.tree.root;
    }
  }

  void goBack() {
    if (_currentNode.parent != null) {
      setState(() => _currentNode = _currentNode.parent!);
      widget.onPositionSelected?.call(_currentNode.fen);
    }
  }

  void goForward() {
    if (_currentNode.children.isEmpty) return;
    final target = _currentNode.children.firstWhere(
      (c) => c.isRepertoireMove,
      orElse: () => _sortedChildren().first,
    );
    _navigateToChild(target);
  }

  void _navigateToChild(BuildTreeNode child) {
    setState(() => _currentNode = child);
    widget.onPositionSelected?.call(child.fen);
  }

  List<BuildTreeNode> _sortedChildren() {
    final children = List<BuildTreeNode>.from(_currentNode.children);
    children.sort((a, b) {
      if (a.isRepertoireMove != b.isRepertoireMove) {
        return a.isRepertoireMove ? -1 : 1;
      }
      return b.moveProbability.compareTo(a.moveProbability);
    });
    return children;
  }

  String _movePath() {
    final moves = _currentNode.getLineSan();
    if (moves.isEmpty) return 'Starting position';
    final sb = StringBuffer();
    final whiteFirst = widget.tree.root.isWhiteToMove;
    for (int i = 0; i < moves.length; i++) {
      final ply = i + (whiteFirst ? 0 : 1);
      if (ply % 2 == 0) {
        sb.write('${(ply ~/ 2) + 1}. ');
      } else if (i == 0 && !whiteFirst) {
        sb.write('${(ply ~/ 2) + 1}... ');
      }
      sb.write('${moves[i]} ');
    }
    return sb.toString().trim();
  }

  int _evalForUs(BuildTreeNode node) => node.evalForUs(widget.playAsWhite);

  String _formatEval(int cpForUs) {
    if (cpForUs.abs() >= 10000) return cpForUs > 0 ? '+M' : '-M';
    final pawns = cpForUs / 100.0;
    return '${pawns >= 0 ? "+" : ""}${pawns.toStringAsFixed(2)}';
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final children = _sortedChildren();
    final isOurMove = _currentNode.isWhiteToMove == widget.playAsWhite;

    double maxProb = 0;
    for (final c in children) {
      if (c.moveProbability > maxProb) maxProb = c.moveProbability;
    }

    return Column(
      children: [
        _buildHeader(isOurMove),
        _buildStatsPanel(),
        _buildWinProbBar(),
        const Divider(height: 1),
        _buildChildrenLabel(children.length, isOurMove),
        Expanded(
          child: children.isEmpty
              ? _buildLeafMessage()
              : ListView.builder(
                  itemCount: children.length,
                  itemBuilder: (_, i) =>
                      _buildChildItem(children[i], maxProb),
                ),
        ),
      ],
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────

  Widget _buildHeader(bool isOurMove) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Colors.grey[700]!, width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isOurMove ? Colors.blue[800] : Colors.orange[800],
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              isOurMove ? 'Our move' : 'Opponent',
              style: const TextStyle(
                fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _movePath(),
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[300],
                fontWeight: FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 32, height: 32,
            child: IconButton(
              icon: Icon(Icons.arrow_back, size: 18, color: Colors.grey[400]),
              padding: EdgeInsets.zero,
              tooltip: 'Back',
              onPressed: _currentNode.parent != null ? goBack : null,
            ),
          ),
          SizedBox(
            width: 32, height: 32,
            child: IconButton(
              icon: Icon(Icons.arrow_forward, size: 18, color: Colors.grey[400]),
              padding: EdgeInsets.zero,
              tooltip: 'Forward',
              onPressed: _currentNode.children.isNotEmpty ? goForward : null,
            ),
          ),
        ],
      ),
    );
  }

  // ── Stats panel ────────────────────────────────────────────────────────

  Widget _buildStatsPanel() {
    final node = _currentNode;
    final evalCp = node.hasEngineEval ? _evalForUs(node) : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.5),
      child: Column(
        children: [
          Row(
            children: [
              if (evalCp != null) ...[
                _statBadge('Eval', _formatEval(evalCp), _evalColor(evalCp)),
                const SizedBox(width: 10),
              ],
              _statBadge(
                'Reach',
                '${(node.cumulativeProbability * 100).toStringAsFixed(2)}%',
                Colors.blue[300]!,
              ),
              if (node.ease != null) ...[
                const SizedBox(width: 10),
                _statBadge(
                  'Ease',
                  node.ease!.toStringAsFixed(3),
                  _easeColor(node.ease!),
                ),
              ],
            ],
          ),
          if (node.hasExpectimax || node.totalGames > 0) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                if (node.hasExpectimax) ...[
                  _statBadge(
                    'Local CPL',
                    '${node.localCpl.toStringAsFixed(1)} cp',
                    _cplColor(node.localCpl),
                  ),
                  const SizedBox(width: 10),
                  _statBadge(
                    'V',
                    '${(node.expectimaxValue * 100).toStringAsFixed(1)}%',
                    _vColor(node.expectimaxValue),
                  ),
                  const SizedBox(width: 10),
                ],
                if (node.totalGames > 0)
                  _statBadge('Games', '${node.totalGames}', Colors.grey[400]!),
              ],
            ),
          ],
          if (node.hasExpectimax && node.subtreeDepth > 0 ||
              node.pruneReason != PruneReason.none ||
              node.trapScore > 0.05) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                if (node.subtreeDepth > 0)
                  _statBadge(
                    'Subtree',
                    '${node.subtreeDepth} ply',
                    Colors.grey[400]!,
                  ),
                if (node.trapScore > 0.05) ...[
                  const SizedBox(width: 10),
                  _statBadge(
                    'Trap',
                    '${(node.trapScore * 100).toStringAsFixed(0)}%',
                    _trapColor(node.trapScore),
                  ),
                ],
                if (node.pruneReason != PruneReason.none) ...[
                  const SizedBox(width: 10),
                  _pruneBadge(node),
                ],
              ],
            ),
          ],
        ],
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
            fontSize: 11, color: valueColor, fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _pruneBadge(BuildTreeNode node) {
    final isHigh = node.pruneReason == PruneReason.evalTooHigh;
    final evalStr = node.pruneEvalCp != null
        ? ' (${_formatEval(node.pruneEvalCp!)})'
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

  // ── Win probability bar ────────────────────────────────────────────────

  Widget _buildWinProbBar() {
    final node = _currentNode;
    if (!node.hasEngineEval) return const SizedBox.shrink();

    final cpForUs = _evalForUs(node);
    final wp = winProbability(cpForUs);

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
              flex: (wp * 1000).round().clamp(1, 999),
              child: Container(color: Colors.white),
            ),
            Expanded(
              flex: ((1 - wp) * 1000).round().clamp(1, 999),
              child: Container(color: Colors.grey[900]),
            ),
          ],
        ),
      ),
    );
  }

  // ── Children label ─────────────────────────────────────────────────────

  Widget _buildChildrenLabel(int count, bool isOurMove) {
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Text(
            isOurMove ? 'Candidate moves' : 'Opponent replies',
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

  // ── Child item ─────────────────────────────────────────────────────────

  Widget _buildChildItem(BuildTreeNode child, double maxProb) {
    final evalCp = child.hasEngineEval ? _evalForUs(child) : null;
    final isSelected = child.isRepertoireMove;

    final barFraction =
        maxProb > 0 ? child.moveProbability / maxProb : 0.0;

    return InkWell(
      onTap: () => _navigateToChild(child),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blue.withValues(alpha: 0.08)
              : null,
          border: Border(
            bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
            left: isSelected
                ? BorderSide(color: Colors.blue[400]!, width: 3)
                : BorderSide.none,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Row 1: Move name + eval chip + probability + V
            Row(
              children: [
                if (isSelected)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.star, size: 14, color: Colors.amber[400],
                    ),
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
                if (evalCp != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: _evalBgColor(evalCp),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _formatEval(evalCp),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _evalTextColor(evalCp),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${(child.moveProbability * 100).toStringAsFixed(1)}%',
                    style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                  ),
                ),
                if (child.hasExpectimax)
                  Text(
                    'V ${(child.expectimaxValue * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: _vColor(child.expectimaxValue),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            // Row 2: probability bar + secondary stats
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
                    _easeColor(child.ease!),
                  ),
                if (child.localCpl > 0)
                  _miniStat(
                    'cpl',
                    child.localCpl.toStringAsFixed(0),
                    _cplColor(child.localCpl),
                  ),
                if (child.totalGames > 0)
                  _miniStat(
                    'games',
                    _compactNumber(child.totalGames),
                    Colors.grey[500]!,
                  ),
                if (child.trapScore > 0.05)
                  _miniStat(
                    'trap',
                    '${(child.trapScore * 100).toStringAsFixed(0)}%',
                    _trapColor(child.trapScore),
                  ),
                if (isSelected && child.repertoireScore != 0)
                  _miniStat(
                    'score',
                    child.repertoireScore.toStringAsFixed(0),
                    Colors.amber[300]!,
                  ),
              ],
            ),
          ],
        ),
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

  // ── Leaf message ───────────────────────────────────────────────────────

  Widget _buildLeafMessage() {
    String message;
    if (_currentNode.pruneReason == PruneReason.evalTooHigh) {
      message =
          'Position is already winning — no further preparation needed.';
    } else if (_currentNode.pruneReason == PruneReason.evalTooLow) {
      message = 'Position is too bad — pruned from the repertoire.';
    } else {
      message = 'Leaf node — no further moves explored.';
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
              style: const TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ── Color helpers ──────────────────────────────────────────────────────

  Color _evalColor(int cpForUs) {
    if (cpForUs > 100) return Colors.green;
    if (cpForUs > 30) return Colors.green[300]!;
    if (cpForUs > -30) return Colors.grey[400]!;
    if (cpForUs > -100) return Colors.orange;
    return Colors.red;
  }

  Color _evalBgColor(int cpForUs) {
    if (cpForUs > 100) return Colors.green[900]!;
    if (cpForUs > 30) return Colors.green[800]!.withValues(alpha: 0.7);
    if (cpForUs > -30) return Colors.grey[800]!;
    if (cpForUs > -100) return Colors.orange[900]!.withValues(alpha: 0.7);
    return Colors.red[900]!;
  }

  Color _evalTextColor(int cpForUs) {
    if (cpForUs > 30) return Colors.green[200]!;
    if (cpForUs > -30) return Colors.grey[300]!;
    return Colors.red[200]!;
  }

  Color _easeColor(double ease) {
    if (ease > 0.8) return Colors.green[300]!;
    if (ease > 0.6) return Colors.yellow[300]!;
    return Colors.orange[300]!;
  }

  Color _cplColor(double cpl) {
    if (cpl < 5) return Colors.grey[400]!;
    if (cpl < 15) return Colors.green[300]!;
    if (cpl < 30) return Colors.yellow[300]!;
    return Colors.orange[300]!;
  }

  Color _trapColor(double trap) {
    if (trap > 0.5) return Colors.red[300]!;
    if (trap > 0.2) return Colors.orange[300]!;
    return Colors.yellow[300]!;
  }

  Color _vColor(double v) {
    if (v > 0.65) return Colors.green[300]!;
    if (v > 0.55) return Colors.green[200]!;
    if (v > 0.45) return Colors.grey[400]!;
    return Colors.orange[300]!;
  }

  String _compactNumber(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}
