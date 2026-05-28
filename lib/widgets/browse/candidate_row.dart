/// Single candidate move row with context-dependent columns.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

import '../../services/candidate_service.dart';

class CandidateRow extends StatelessWidget {
  final CandidateMove candidate;
  final bool isOurTurn;
  final bool isHovered;
  final VoidCallback onTap;
  final VoidCallback onHover;
  final VoidCallback onHoverEnd;

  const CandidateRow({
    super.key,
    required this.candidate,
    required this.isOurTurn,
    required this.isHovered,
    required this.onTap,
    required this.onHover,
    required this.onHoverEnd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      onEnter: (_) => onHover(),
      onExit: (_) => onHoverEnd(),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isHovered
                ? theme.colorScheme.surfaceContainerHighest
                : null,
            border: Border(
              left: BorderSide(
                width: 3,
                color: candidate.inRepertoire
                    ? Colors.green
                    : (candidate.subtreeTrapCount ?? 0) > 0
                        ? Colors.orange
                        : Colors.transparent,
              ),
            ),
          ),
          child: Row(
            children: [
              _buildRepertoireIndicator(),
              const SizedBox(width: 8),
              _buildMoveSan(theme),
              const Spacer(),
              if (isOurTurn) ..._buildOurTurnColumns(),
              if (!isOurTurn) ..._buildOpponentTurnColumns(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRepertoireIndicator() {
    if (candidate.inRepertoire) {
      return const Icon(Icons.check_circle, size: 14, color: Colors.green);
    }
    if (candidate.isRepertoireMove == true) {
      return const Icon(Icons.star, size: 14, color: Colors.amber);
    }
    return const SizedBox(width: 14);
  }

  Widget _buildMoveSan(ThemeData theme) {
    return Text(
      candidate.san,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: candidate.inRepertoire
            ? theme.colorScheme.primary
            : null,
      ),
    );
  }

  List<Widget> _buildOurTurnColumns() {
    return [
      if (candidate.evalCp != null) ...[
        _EvalChip(candidate.evalCp!),
        const SizedBox(width: 6),
      ],
      if (candidate.myEase != null) ...[
        _EaseBar(candidate.myEase!),
        const SizedBox(width: 6),
      ],
      if ((candidate.subtreeTrapCount ?? 0) > 0) ...[
        _TrapBadge(candidate.subtreeTrapCount!),
        const SizedBox(width: 6),
      ],
      if (candidate.coverageDelta != null && candidate.coverageDelta! > 0)
        _CoverageDelta(candidate.coverageDelta!),
    ];
  }

  List<Widget> _buildOpponentTurnColumns(ThemeData theme) {
    return [
      if (candidate.dbFrequency != null) ...[
        Text('${(candidate.dbFrequency! * 100).toStringAsFixed(0)}%',
            style: const TextStyle(fontSize: 11)),
        const SizedBox(width: 8),
      ],
      if (candidate.dbGames != null) ...[
        Text(_formatGames(candidate.dbGames!),
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        const SizedBox(width: 8),
      ],
      if (candidate.dbWhiteWin != null)
        _ResultBar(
          white: candidate.dbWhiteWin!,
          draw: candidate.dbDraw ?? 0,
          black: candidate.dbBlackWin ?? 0,
        ),
    ];
  }

  String _formatGames(int games) {
    if (games >= 1000000) return '${(games / 1000000).toStringAsFixed(1)}M';
    if (games >= 1000) return '${(games / 1000).toStringAsFixed(1)}k';
    return '$games';
  }
}

class _EvalChip extends StatelessWidget {
  final int cp;
  const _EvalChip(this.cp);

  @override
  Widget build(BuildContext context) {
    final pawns = cp / 100.0;
    final text = '${pawns >= 0 ? "+" : ""}${pawns.toStringAsFixed(2)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.cpEvalBg(cp),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: AppColors.cpEval(cp))),
    );
  }
}

class _EaseBar extends StatelessWidget {
  final double ease;
  const _EaseBar(this.ease);

  @override
  Widget build(BuildContext context) {
    final filled = (ease * 5).round().clamp(0, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        return Container(
          width: 4,
          height: 10,
          margin: const EdgeInsets.only(right: 1),
          decoration: BoxDecoration(
            color: i < filled ? Colors.blue : Colors.grey.shade300,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}

class _TrapBadge extends StatelessWidget {
  final int count;
  const _TrapBadge(this.count);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: 10, color: Colors.orange.shade700),
          Text('$count',
              style: TextStyle(
                  fontSize: 10, color: Colors.orange.shade700)),
        ],
      ),
    );
  }
}

class _CoverageDelta extends StatelessWidget {
  final double delta;
  const _CoverageDelta(this.delta);

  @override
  Widget build(BuildContext context) {
    return Text('+${delta.toStringAsFixed(1)}%',
        style: const TextStyle(
            fontSize: 10,
            color: Colors.green,
            fontWeight: FontWeight.w500));
  }
}

class _ResultBar extends StatelessWidget {
  final double white;
  final double draw;
  final double black;

  const _ResultBar({
    required this.white,
    required this.draw,
    required this.black,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      height: 8,
      child: Row(
        children: [
          Expanded(
              flex: (white * 100).round(),
              child: Container(color: Colors.white)),
          Expanded(
              flex: (draw * 100).round(),
              child: Container(color: Colors.grey.shade400)),
          Expanded(
              flex: (black * 100).round(),
              child: Container(color: Colors.grey.shade800)),
        ],
      ),
    );
  }
}
