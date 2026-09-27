import 'package:flutter/material.dart';

import '../../chess/tournament/result.dart';
import '../../chess/tournament/standings.dart';

class TournamentStandingsTable extends StatefulWidget {
  const TournamentStandingsTable({super.key, required this.tournament});
  final Tournament tournament;
  @override
  State<TournamentStandingsTable> createState() => _TableState();
}

class _TableState extends State<TournamentStandingsTable> {
  bool _statistics = false;
  @override
  Widget build(BuildContext context) {
    final rows = widget.tournament.standings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Show rating statistics'),
          value: _statistics,
          onChanged: (v) => setState(() => _statistics = v ?? false),
        ),
        if (rows.every((r) => r.score.played == 0))
          const Text('No games yet — the crosstable fills in as they finish.')
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                const DataColumn(label: Text('#')),
                const DataColumn(label: Text('Engine')),
                const DataColumn(label: Text('Score')),
                ...[
                  'W',
                  'D',
                  'L',
                ].map((s) => DataColumn(label: Text(s), numeric: true)),
                if (_statistics) ...[
                  _heading('Draw %', 'Draws divided by completed games.'),
                  _heading(
                    'Elo ±',
                    'Score-implied Elo difference and approximate 95% interval half-width. Assumes independent games; small or all-draw samples can understate uncertainty.',
                  ),
                  _heading(
                    'LOS',
                    'Normal approximation from wins minus losses. Draws carry no directional evidence.',
                  ),
                  _heading(
                    'SB',
                    'Sonneborn–Berger: opponents’ total scores, weighted by the points scored against them.',
                  ),
                ],
                for (final r in rows) DataColumn(label: Text('vs ${r.name}')),
              ],
              rows: [
                for (final (rank, row) in rows.indexed)
                  _row(row, rank + 1, rows),
              ],
            ),
          ),
      ],
    );
  }

  DataColumn _heading(String name, String help) => DataColumn(
    label: Tooltip(message: help, child: Text(name)),
    numeric: true,
  );
  DataRow _row(
    TournamentStanding row,
    int rank,
    List<TournamentStanding> rows,
  ) {
    final s = row.score;
    return DataRow(
      cells: [
        DataCell(Text('$rank')),
        DataCell(Text(row.name)),
        DataCell(Text(s.label)),
        DataCell(Text('${s.wins}')),
        DataCell(Text('${s.draws}')),
        DataCell(Text('${s.losses}')),
        if (_statistics) ...[
          DataCell(
            Text(
              s.played == 0
                  ? '—'
                  : '${(100 * s.draws / s.played).toStringAsFixed(1)}%',
            ),
          ),
          DataCell(
            Text(
              s.elo == null
                  ? '—'
                  : '${s.elo!.toStringAsFixed(0)} ±${s.margin!.toStringAsFixed(0)}',
            ),
          ),
          DataCell(Text('${(100 * s.superiority).toStringAsFixed(1)}%')),
          DataCell(Text(row.sonnebornBerger.toStringAsFixed(2))),
        ],
        for (final opponent in rows)
          DataCell(
            row.seat == opponent.seat
                ? const Text('—')
                : _pair(row.opponents[opponent.seat]),
          ),
      ],
    );
  }

  Widget _pair(MatchScore score) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(score.label),
      Text(
        '${score.wins} W · ${score.draws} D · ${score.losses} L',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    ],
  );
}
