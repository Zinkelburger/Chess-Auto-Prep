/// The results summary — standings on the left, head-to-head on the right.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../models/crosstable.dart';
import '../models/tournament_config.dart';

class CrosstableView extends StatelessWidget {
  const CrosstableView({
    super.key,
    required this.crosstable,
    required this.config,
  });

  final Crosstable crosstable;
  final TournamentConfig config;

  @override
  Widget build(BuildContext context) {
    if (crosstable.isEmpty || crosstable.totalGames == 0) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'No games yet — the crosstable fills in as they finish.',
          style: AppTextStyles.muted,
        ),
      );
    }

    final standings = crosstable.standings;
    // Opponent columns in standings order, so the grid reads the same way
    // top-to-bottom and left-to-right.
    final opponents = standings.map((r) => r.engineIndex).toList();

    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 34,
          dataRowMinHeight: 32,
          dataRowMaxHeight: 38,
          horizontalMargin: 12,
          columnSpacing: 18,
          headingTextStyle: AppTextStyles.caption.copyWith(
            fontWeight: FontWeight.w600,
            color: AppColors.onSurfaceSoft,
          ),
          dataTextStyle: AppTextStyles.body,
          columns: [
            const DataColumn(label: Text('#')),
            const DataColumn(label: Text('Engine')),
            const DataColumn(label: Text('Score'), numeric: true),
            const DataColumn(label: Text('W'), numeric: true),
            const DataColumn(label: Text('D'), numeric: true),
            const DataColumn(label: Text('L'), numeric: true),
            const DataColumn(label: Text('Draw %'), numeric: true),
            const DataColumn(
              label: _HeaderWithHint(
                label: 'Elo ±',
                hint:
                    'Rating difference implied by the score, with the 95% '
                    'confidence interval. A margin wider than the estimate '
                    'means the match has not decided anything yet.',
              ),
              numeric: true,
            ),
            const DataColumn(
              label: _HeaderWithHint(
                label: 'LOS',
                hint:
                    'Likelihood of superiority — the chance the win/loss '
                    'split is a real edge rather than noise. Draws carry no '
                    'information here.',
              ),
              numeric: true,
            ),
            const DataColumn(
              label: _HeaderWithHint(
                label: 'SB',
                hint:
                    'Sonneborn-Berger tiebreak: the full score of everyone '
                    'you beat plus half the score of everyone you drew.',
              ),
              numeric: true,
            ),
            for (final index in opponents)
              DataColumn(label: Text('vs ${config.engines[index].name}')),
          ],
          rows: [
            for (final row in standings)
              DataRow(
                cells: [
                  DataCell(Text('${row.rank}')),
                  DataCell(
                    Text(
                      row.name,
                      style: AppTextStyles.bodyStrong,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DataCell(
                    Text(row.scoreLabel, style: AppTextStyles.bodyStrong),
                  ),
                  DataCell(Text('${row.wins}')),
                  DataCell(Text('${row.draws}')),
                  DataCell(Text('${row.losses}')),
                  DataCell(
                    Text('${(row.drawFraction * 100).toStringAsFixed(0)}%'),
                  ),
                  DataCell(_EloCell(row: row)),
                  DataCell(
                    Text(
                      '${(row.likelihoodOfSuperiority * 100).toStringAsFixed(1)}%',
                    ),
                  ),
                  DataCell(Text(row.sonnebornBerger.toStringAsFixed(1))),
                  for (final index in opponents)
                    DataCell(
                      _HeadToHeadCell(
                        cell: index == row.engineIndex
                            ? null
                            : crosstable.cell(row.engineIndex, index),
                        isSelf: index == row.engineIndex,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _EloCell extends StatelessWidget {
  const _EloCell({required this.row});

  final StandingsRow row;

  @override
  Widget build(BuildContext context) {
    final elo = row.eloDiff;
    if (elo == null) {
      return const Text('—', style: AppTextStyles.muted);
    }
    final margin = row.eloMargin;
    final color = elo > 0
        ? AppColors.success
        : elo < 0
        ? AppColors.danger
        : AppColors.onSurfaceMuted;
    return Text(
      '${elo >= 0 ? '+' : ''}${elo.toStringAsFixed(0)}'
      '${margin == null ? '' : ' ±${margin.toStringAsFixed(0)}'}',
      style: AppTextStyles.body.copyWith(color: color),
    );
  }
}

/// `5.5/10  =1=0==1==0` — the score against one opponent and the games that
/// made it, in the order they were played.
class _HeadToHeadCell extends StatelessWidget {
  const _HeadToHeadCell({required this.cell, required this.isSelf});

  final CrosstableCell? cell;
  final bool isSelf;

  @override
  Widget build(BuildContext context) {
    if (isSelf) {
      return const Text('·', style: AppTextStyles.muted);
    }
    final data = cell;
    if (data == null || data.played == 0) {
      return const Text('—', style: AppTextStyles.muted);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${_trim(data.points)}/${data.played}',
          style: AppTextStyles.bodyStrong,
        ),
        const SizedBox(width: 8),
        for (final letter in data.results)
          Padding(
            padding: const EdgeInsets.only(right: 1),
            child: Text(
              letter,
              style: AppTextStyles.body.copyWith(
                fontFeatures: const [],
                color: switch (letter) {
                  '1' => AppColors.success,
                  '0' => AppColors.danger,
                  _ => AppColors.onSurfaceMuted,
                },
              ),
            ),
          ),
      ],
    );
  }

  static String _trim(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}

class _HeaderWithHint extends StatelessWidget {
  const _HeaderWithHint({required this.label, required this.hint});

  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: hint,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          const SizedBox(width: 3),
          const Icon(
            Icons.info_outline,
            size: 12,
            color: AppColors.onSurfaceDim,
          ),
        ],
      ),
    );
  }
}
