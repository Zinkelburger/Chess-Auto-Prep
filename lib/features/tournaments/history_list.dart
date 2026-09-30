import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../chess/tournament/result.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'tournament_run.dart';

class TournamentHistory extends StatefulWidget {
  const TournamentHistory({super.key, required this.run});
  final TournamentRun run;
  @override
  State<TournamentHistory> createState() => _HistoryState();
}

class _HistoryState extends State<TournamentHistory> {
  final _search = TextEditingController();
  String _query = '';
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.run.history
        .where(
          (t) =>
              '${t.config.name} ${t.config.json['openingLabel'] ?? ''} ${t.config.engines.map((e) => e.name).join(' ')}'
                  .toLowerCase()
                  .contains(_query.toLowerCase()),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(Space.s),
          child: SearchField(
            controller: _search,
            hint: 'Name, engine or opening',
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        if (history.isEmpty && _query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(Space.m),
            child: Text('No tournament matches "$_query".'),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: history.length,
            itemBuilder: (context, i) {
              final t = history[i];
              final group = _dateGroup(t);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (i == 0 || group != _dateGroup(history[i - 1]))
                    Padding(
                      padding: const EdgeInsets.all(Space.s),
                      child: Text(
                        group,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ListTile(
                    selected: widget.run.selected?.id == t.id,
                    title: Text(t.config.name),
                    subtitle: Text(
                      '${t.status} · ${t.games.length}/${t.config.gameCount} games\n${_scores(t)}',
                    ),
                    onTap: () => widget.run.select(t),
                  ),
                  if (t.status == 'running' && t.config.gameCount > 0)
                    LinearProgressIndicator(
                      value: t.games.length / t.config.gameCount,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

String _scores(Tournament t) => t.standings
    .map((r) => '${r.name} ${r.score.points.toStringAsFixed(1)}')
    .join(' · ');
String _dateGroup(Tournament t) {
  final created = DateTime.tryParse('${t.json['createdAt']}')?.toLocal();
  if (created == null) return 'Unknown date';
  final now = DateTime.now();
  final day = DateTime(created.year, created.month, created.day);
  final today = DateTime(now.year, now.month, now.day);
  if (day == today) return 'Today';
  if (day == DateTime(now.year, now.month, now.day - 1)) return 'Yesterday';
  return DateFormat('MMMM yyyy', 'en').format(created);
}
