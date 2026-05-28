/// Coherence analysis panel — shows clusters, scores, and risk lines.
library;

import 'package:flutter/material.dart';

import '../services/coherence_service.dart';
import '../theme/app_colors.dart';

class CoherencePanel extends StatelessWidget {
  final CoherenceResult result;
  final Map<String, String> lineNames;

  const CoherencePanel({
    super.key,
    required this.result,
    this.lineNames = const {},
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSummary(theme),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final cluster in result.clusters)
                _buildCluster(theme, cluster),
              if (_riskLines.isNotEmpty) ...[
                const SizedBox(height: 16),
                _buildRiskSection(theme),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSummary(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _SummaryItem(
            label: 'Coherence',
            value: result.globalCoherence.toStringAsFixed(2),
            color: _coherenceColor(result.globalCoherence),
          ),
          _SummaryItem(
            label: 'Clusters',
            value: '${result.clusters.length}',
            color: theme.colorScheme.primary,
          ),
          _SummaryItem(
            label: 'Top-3 coverage',
            value: '${(result.topNCoverage * 100).round()}%',
            color: AppColors.evalPositive,
          ),
        ],
      ),
    );
  }

  Widget _buildCluster(ThemeData theme, CoherenceCluster cluster) {
    final lineCount = cluster.lineIds.length;
    final probPct = (cluster.probabilityMass * 100).toStringAsFixed(0);
    final isUnclustered = cluster.id == 'unclustered';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(
          isUnclustered ? Icons.warning_amber : Icons.folder,
          color: isUnclustered ? AppColors.warning : theme.colorScheme.primary,
          size: 20,
        ),
        title: Text(cluster.autoName,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text('$lineCount lines, $probPct% of games'),
        trailing: isUnclustered
            ? null
            : Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _coherenceColor(
                          cluster.signature.support)
                      .withAlpha(30),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                    '${(cluster.signature.support * 100).round()}%',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _coherenceColor(
                            cluster.signature.support))),
              ),
        children: [
          if (cluster.signature.items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 4),
              child: Wrap(
                spacing: 4,
                children: cluster.signature.items
                    .map((m) => Chip(
                          label: Text(m,
                              style: const TextStyle(fontSize: 10)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ))
                    .toList(),
              ),
            ),
          for (final lineId in cluster.lineIds.take(5))
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text(
                  lineNames[lineId] ?? lineId,
                  style: const TextStyle(fontSize: 12)),
              trailing: _lineCoherenceBadge(lineId),
            ),
          if (cluster.lineIds.length > 5)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                  '+ ${cluster.lineIds.length - 5} more lines',
                  style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Widget _lineCoherenceBadge(String lineId) {
    final score = result.lineCoherenceById[lineId] ?? 0;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _coherenceColor(score).withAlpha(30),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(score.toStringAsFixed(2),
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: _coherenceColor(score))),
    );
  }

  List<String> get _riskLines {
    return result.lineCoherenceById.entries
        .where((e) => e.value < 0.3)
        .map((e) => e.key)
        .toList();
  }

  Widget _buildRiskSection(ThemeData theme) {
    return Card(
      color: AppColors.warningSurface.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber,
                    size: 16, color: AppColors.warning),
                const SizedBox(width: 4),
                Text('Low Coherence Lines',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: AppColors.warning)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
                'These lines share few patterns with the rest of your repertoire '
                'and may be harder to remember.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            for (final lineId in _riskLines.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(lineNames[lineId] ?? lineId,
                            style: const TextStyle(fontSize: 12))),
                    _lineCoherenceBadge(lineId),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Color _coherenceColor(double score) {
    return AppColors.coherence(score);
  }
}

class _SummaryItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _SummaryItem({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color)),
        Text(label,
            style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }
}
