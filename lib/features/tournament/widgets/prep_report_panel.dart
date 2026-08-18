/// The ranked study list produced by a prep run.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_colors.dart';
import '../services/tournament_prep_service.dart';
import '../services/tournament_session.dart';

class PrepReportPanel extends StatelessWidget {
  final TournamentSession session;

  const PrepReportPanel({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final report = session.report;
    if (report == null) {
      return Card(
        color: AppColors.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            'No prep run yet. Import a field, resolve accounts, pick a '
            'repertoire, then press "Prepare tournament".',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
          ),
        ),
      );
    }

    final covers80 = report.topByCoverage(0.8).length;

    return Card(
      color: AppColors.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Lines to know',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              report.positions.isEmpty
                  ? 'No gaps found — your repertoire covers what this field '
                        'actually plays.'
                  : '${report.positions.length} gaps across '
                        '${report.clashReports.length} clash runs. '
                        'The top $covers80 cover 80% of what you are likely '
                        'to face.',
              style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
            ),
            const SizedBox(height: 12),
            ...report.positions
                .take(20)
                .toList()
                .asMap()
                .entries
                .map((e) => _PositionRow(index: e.key + 1, position: e.value)),
            if (report.positions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy prep PGN'),
                    onPressed: () => _copy(
                      context,
                      session.exportPgn(),
                      'Prep PGN copied — paste it into Study.',
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy briefing'),
                    onPressed: () => _copy(
                      context,
                      session.exportBriefing(),
                      'Briefing copied.',
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy roster CSV'),
                    onPressed: () => _copy(
                      context,
                      session.exportRosterCsv(),
                      'Roster CSV copied.',
                    ),
                  ),
                ],
              ),
            ],
            if (report.warnings.isNotEmpty) ...[
              const SizedBox(height: 14),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '${report.warnings.length} notes',
                  style: const TextStyle(fontSize: 13),
                ),
                children: report.warnings
                    .map(
                      (w) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '• $w',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.onSurfaceMuted,
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _copy(BuildContext context, String text, String message) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _PositionRow extends StatelessWidget {
  final int index;
  final PrepPosition position;

  const _PositionRow({required this.index, required this.position});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$index.',
              style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: position.weAreWhite
                            ? AppColors.ink
                            : AppColors.surfaceHighlight,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        position.weAreWhite ? 'W' : 'B',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: position.weAreWhite
                              ? AppColors.surface
                              : AppColors.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        position.lineWithMove,
                        style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${(position.score * 100).toStringAsFixed(2)}% of your games · '
                  '${position.opponentCount} opponent'
                  '${position.opponentCount == 1 ? '' : 's'}'
                  '${position.transposes ? ' · transposes back into your book' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: position.transposes
                        ? AppColors.onSurfaceDim
                        : AppColors.onSurfaceMuted,
                  ),
                ),
                Text(
                  position.opponents
                      .take(3)
                      .map(
                        (o) =>
                            '${o.playerName} '
                            '(${(o.pairingProb * 100).toStringAsFixed(0)}%)',
                      )
                      .join(', '),
                  style: TextStyle(fontSize: 11, color: AppColors.onSurfaceDim),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
