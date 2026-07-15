/// Single candidate move row with context-dependent columns.
library;

import 'package:flutter/material.dart';

import '../../../services/coherence_service.dart';
import '../../../theme/app_colors.dart';

import 'package:chess_auto_prep/features/browse/services/candidate_service.dart';

class CandidateRow extends StatelessWidget {
  final CandidateMove candidate;
  final bool isHovered;
  final VoidCallback onTap;
  final VoidCallback onHover;
  final VoidCallback onHoverEnd;
  final int? trapCount;
  final bool isTrapExpanded;
  final VoidCallback? onExpandTraps;
  final CoherenceCandidateHint? coherenceHint;

  const CandidateRow({
    super.key,
    required this.candidate,
    required this.isHovered,
    required this.onTap,
    required this.onHover,
    required this.onHoverEnd,
    this.trapCount,
    this.isTrapExpanded = false,
    this.onExpandTraps,
    this.coherenceHint,
  });

  int get _trapCount => trapCount ?? candidate.subtreeTrapCount ?? 0;

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
            color: isHovered ? theme.colorScheme.surfaceContainerHighest : null,
            border: Border(
              left: BorderSide(
                width: 3,
                color: _trapCount > 0 ? AppColors.warning : Colors.transparent,
              ),
            ),
          ),
          child: Row(
            children: [
              _buildMoveSan(theme),
              const Spacer(),
              ..._buildColumns(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMoveSan(ThemeData theme) {
    return Text(
      candidate.san,
      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    );
  }

  List<Widget> _buildColumns(ThemeData theme) {
    return [
      if (candidate.evalCp != null) ...[
        _EvalChip(candidate.evalCp!),
        const SizedBox(width: 6),
      ],
      if (candidate.dbFrequency != null) ...[
        Text(
          '${(candidate.dbFrequency! * 100).toStringAsFixed(0)}%',
          style: const TextStyle(fontSize: 11),
        ),
        const SizedBox(width: 6),
      ],
      if (candidate.dbGames != null) ...[
        Text(
          _formatGames(candidate.dbGames!),
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
        const SizedBox(width: 6),
      ],
      if (candidate.dbWhiteWin != null) ...[
        _ResultBar(
          white: candidate.dbWhiteWin!,
          draw: candidate.dbDraw ?? 0,
          black: candidate.dbBlackWin ?? 0,
        ),
        const SizedBox(width: 6),
      ],
      if (candidate.myEase != null) ...[
        _EaseBar(candidate.myEase!),
        const SizedBox(width: 6),
      ],
      if (_trapCount > 0) ...[
        _TrapBadge(
          count: _trapCount,
          isExpanded: isTrapExpanded,
          onExpandTraps: onExpandTraps,
        ),
        const SizedBox(width: 6),
      ],
      if (candidate.coverageDelta != null && candidate.coverageDelta! > 0)
        _CoverageDelta(candidate.coverageDelta!),
      if (coherenceHint != null) ...[
        const SizedBox(width: 6),
        _CoherenceChip(hint: coherenceHint!),
      ],
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
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: AppColors.cpEval(cp),
        ),
      ),
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
            color: i < filled ? AppColors.lichessDb : Colors.grey.shade300,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}

class _TrapBadge extends StatelessWidget {
  final int count;
  final bool isExpanded;
  final VoidCallback? onExpandTraps;

  const _TrapBadge({
    required this.count,
    this.isExpanded = false,
    this.onExpandTraps,
  });

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt, size: 10, color: AppColors.warning),
          Text(
            '$count',
            style: const TextStyle(fontSize: 10, color: AppColors.warning),
          ),
          if (onExpandTraps != null) ...[
            const SizedBox(width: 2),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 12,
              color: AppColors.warning,
            ),
          ],
        ],
      ),
    );

    if (onExpandTraps != null) {
      return InkWell(
        onTap: onExpandTraps,
        borderRadius: BorderRadius.circular(4),
        child: badge,
      );
    }
    return badge;
  }
}

class _CoherenceChip extends StatelessWidget {
  final CoherenceCandidateHint hint;

  const _CoherenceChip({required this.hint});

  @override
  Widget build(BuildContext context) {
    final label = hint.clusterName != null
        ? hint.clusterName!
        : hint.score.toStringAsFixed(2);
    return Tooltip(
      message: 'Coherence ${hint.score.toStringAsFixed(2)}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.maia.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hub, size: 10, color: AppColors.maia),
            const SizedBox(width: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: AppColors.maia),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverageDelta extends StatelessWidget {
  final double delta;
  const _CoverageDelta(this.delta);

  @override
  Widget build(BuildContext context) {
    return Text(
      '+${delta.toStringAsFixed(1)}%',
      style: const TextStyle(
        fontSize: 10,
        color: AppColors.success,
        fontWeight: FontWeight.w500,
      ),
    );
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
            child: Container(color: Colors.white),
          ),
          Expanded(
            flex: (draw * 100).round(),
            child: Container(color: Colors.grey.shade400),
          ),
          Expanded(
            flex: (black * 100).round(),
            child: Container(color: Colors.grey.shade800),
          ),
        ],
      ),
    );
  }
}
