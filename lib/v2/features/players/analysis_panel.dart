import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../engines/engine_line.dart';
import '../../ui/choice_dialog.dart';
import '../../ui/choice_field.dart';
import '../../ui/number_field.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import '../../chess/players/player.dart';
import 'player_analysis.dart';
import 'player_dialogs.dart';
import 'player_games.dart';
import 'player_hunt.dart';
import 'players.dart';

class AnalysisPanel extends StatefulWidget {
  const AnalysisPanel({
    super.key,
    required this.players,
    required this.analysis,
    required this.hunt,
    required this.onOpen,
    required this.onChoose,
    required this.onImport,
    required this.onDirectory,
    required this.trailing,
  });
  final Players players;
  final PlayerAnalysis analysis;
  final PlayerHunt hunt;
  final void Function(int game, PlayerPosition? at) onOpen;
  final ValueChanged<Player> onChoose;
  final VoidCallback onImport, onDirectory;
  final Widget trailing;
  @override
  State<AnalysisPanel> createState() => _AnalysisPanelState();
}

class _AnalysisPanelState extends State<AnalysisPanel> {
  late final _search = TextEditingController(text: widget.analysis.query);
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  PlayerAnalysis get owner => widget.analysis;
  Future<void> _choose() async {
    final player = await showChoiceDialog<Player>(
      context,
      title: 'Choose a player',
      options: widget.players.players,
      label: (p) => p.name,
      hint: 'Search players',
      empty: 'No players saved. Add a player first.',
    );
    if (player != null && mounted) {
      _search.clear();
      widget.onChoose(player);
    }
  }

  Future<void> _add() async {
    final player = await editPlayer(context, widget.players);
    if (player != null && mounted) {
      _search.clear();
      widget.onChoose(player);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([owner, widget.players, widget.hunt]),
    builder: (context, _) {
      final player = owner.player;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.m,
              Space.s,
              Space.xs,
              Space.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    player?.name ?? 'Player analysis',
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                widget.trailing,
              ],
            ),
          ),
          Expanded(child: player == null ? _picker() : _analysis(player)),
        ],
      );
    },
  );
  Widget _picker() => ListView(
    padding: const EdgeInsets.all(Space.m),
    children: [
      const Text('Whose games would you like to prepare against?'),
      const SizedBox(height: Space.m),
      FilledButton.icon(
        onPressed: _add,
        icon: const Icon(Icons.person_add_outlined),
        label: const Text('Add player'),
      ),
      TextButton(
        onPressed: widget.onDirectory,
        child: const Text('Players & prep'),
      ),
      if (widget.players.error != null) ...[
        Text(widget.players.error!),
        TextButton(
          onPressed: widget.players.load,
          child: const Text('Try again'),
        ),
      ],
      for (final player in widget.players.players)
        ListTile(
          title: Text(player.name),
          subtitle: Text(player.accounts.map((a) => a.username).join(', ')),
          onTap: () => widget.onChoose(player),
        ),
    ],
  );
  Widget _analysis(Player player) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: Space.xs,
              children: [
                TextButton(
                  onPressed: _choose,
                  child: const Text('Change player'),
                ),
                TextButton(
                  onPressed: widget.onDirectory,
                  child: const Text('Players & prep'),
                ),
              ],
            ),
            Wrap(
              spacing: Space.s,
              children: [
                OutlinedButton.icon(
                  onPressed: owner.busy || player.accounts.isEmpty
                      ? null
                      : () => owner.select(player, download: true),
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Get games'),
                ),
                TextButton(
                  onPressed: owner.busy ? null : widget.onImport,
                  child: const Text('Add PGN…'),
                ),
                IconButton(
                  tooltip: 'Reload saved games',
                  onPressed: owner.busy ? null : () => owner.select(player),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (owner.busy) ...[
              const LinearProgressIndicator(),
              TextButton(onPressed: owner.cancel, child: const Text('Cancel')),
            ],
            if (owner.status != null)
              Text(owner.status!, style: Theme.of(context).textTheme.bodySmall),
            if (owner.error != null)
              Text(
                owner.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            for (final warning in owner.warnings)
              Text(
                warning,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: Space.s),
            SegmentedButton<Side>(
              segments: const [
                ButtonSegment(value: Side.white, label: Text('As White')),
                ButtonSegment(value: Side.black, label: Text('As Black')),
              ],
              selected: {owner.side},
              onSelectionChanged: (v) => owner.setSide(v.single),
            ),
            const SizedBox(height: Space.s),
            SearchField(
              controller: _search,
              hint: 'Search opponent, event or opening',
              onChanged: owner.search,
            ),
            _filters(),
            SegmentedButton<PlayerList>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: PlayerList.openings,
                  label: Text('Positions'),
                ),
                ButtonSegment(value: PlayerList.games, label: Text('Games')),
                ButtonSegment(
                  value: PlayerList.weaknesses,
                  label: Text('Weaknesses'),
                ),
              ],
              selected: {owner.list},
              onSelectionChanged: (v) => owner.configure(list: v.single),
            ),
            const SizedBox(height: Space.s),
          ],
        ),
      ),
      Expanded(
        child: switch (owner.list) {
          PlayerList.openings => _positions(),
          PlayerList.games => _games(),
          PlayerList.weaknesses => _weaknesses(),
        },
      ),
    ],
  );
  Widget _filters() => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      icon: const Icon(Icons.filter_list),
      label: Text('Filters · ${owner.gameIndexes.length} games'),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Player analysis filters'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: ListenableBuilder(
                listenable: owner,
                builder: (context, _) => _filterFields(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _filterFields() => ExpansionTile(
    initiallyExpanded: true,
    tilePadding: EdgeInsets.zero,
    title: Text('Filters · ${owner.gameIndexes.length} games'),
    children: [
      NumberField(
        label: 'Minimum games',
        value: owner.minGames,
        min: 1,
        max: 10000,
        onChanged: (v) => owner.configure(minGames: v),
      ),
      NumberField(
        label: 'From move',
        value: owner.minPly ~/ 2,
        min: 0,
        max: 20,
        onChanged: (v) => owner.configure(minPly: v * 2),
      ),
      ChoiceField(
        text: _orderName(owner.order),
        options: PositionOrder.values.map(_orderName).toList(),
        hint: 'Sort positions',
        onChanged: (v) {
          final order = PositionOrder.values
              .where((o) => _orderName(o) == v)
              .firstOrNull;
          if (order != null) owner.configure(order: order);
        },
      ),
      NumberField(
        label: 'Games per download / account',
        value: owner.maxGames,
        min: 1,
        max: 10000,
        step: 100,
        onChanged: (v) {
          owner.maxGames = v;
          owner.changed();
        },
      ),
      ChoiceField(
        text: owner.recentDays == null
            ? 'All dates'
            : 'Last ${owner.recentDays} days',
        options: const [
          'All dates',
          'Last 30 days',
          'Last 90 days',
          'Last 180 days',
          'Last 365 days',
        ],
        hint: 'Date range',
        onChanged: (v) {
          if (v == 'All dates') {
            owner.recentDays = null;
          } else {
            final days = int.tryParse(v.split(' ').elementAtOrNull(1) ?? '');
            if (days == null) return;
            owner.recentDays = days;
          }
          owner.changed();
        },
      ),
      Wrap(
        spacing: Space.xs,
        children: [
          for (final speed in [
            'Bullet',
            'Blitz',
            'Rapid',
            'Classical',
            'Other',
          ])
            FilterChip(
              label: Text(speed),
              selected: owner.speeds.contains(speed),
              onSelected: (v) {
                owner.speeds = {...owner.speeds};
                v ? owner.speeds.add(speed) : owner.speeds.remove(speed);
                owner.changed();
              },
            ),
        ],
      ),
      const Text('No time controls selected includes all games.'),
      const SizedBox(height: Space.s),
    ],
  );
  String _orderName(PositionOrder value) => switch (value) {
    PositionOrder.frequent => 'Most played',
    PositionOrder.lowScore => 'Lowest score',
    PositionOrder.highScore => 'Highest score',
    PositionOrder.badEval => 'Worst engine evaluation',
  };
  Widget _positions() {
    final positions = owner.positions.take(100).toList();
    if (owner.order == PositionOrder.badEval && owner.evals.isEmpty)
      return Center(
        child: TextButton(
          onPressed: () => owner.configure(list: PlayerList.weaknesses),
          child: const Text('Run engine analysis to rank evaluations'),
        ),
      );
    if (positions.isEmpty)
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(Space.m),
          child: Text(
            'No positions match. Try the other colour or adjust the filters.',
          ),
        ),
      );
    return ListView.builder(
      itemCount: positions.length,
      itemBuilder: (context, i) {
        final at = positions[i];
        return ListTile(
          title: Text(at.label, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${at.count} games · ${at.wins}W ${at.draws}D ${at.losses}L${at.unknown == 0 ? '' : ' · ${at.unknown} unfinished'}${at.score == null ? '' : ' · ${(at.score! * 100).round()}% score'}${owner.evals[at.key] == null ? '' : ' · ${Centipawns(owner.evals[at.key]!).text}'}',
          ),
          onTap: () => widget.onOpen(at.games.first, at),
        );
      },
    );
  }

  Widget _games() {
    final indexes = owner.gameIndexes;
    if (indexes.isEmpty)
      return const Center(child: Text('No games match these filters.'));
    return ListView.builder(
      itemCount: indexes.length,
      itemBuilder: (context, i) {
        final index = indexes[i], game = owner.corpus!.games[index];
        return ListTile(
          title: Text(game.title, maxLines: 2),
          subtitle: Text('${game.date} · ${game.result} · ${game.tag('ECO')}'),
          onTap: () => widget.onOpen(index, null),
        );
      },
    );
  }

  Widget _weaknesses() {
    final hunt = widget.hunt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _engineControls(),
        Expanded(
          child: ListView.builder(
            itemCount: hunt.findings.length,
            itemBuilder: (context, i) {
              final finding = hunt.findings[i];
              return ListTile(
                title: Text('${finding.title} · ${finding.score.text}'),
                subtitle: Text(
                  '${finding.position.count} games\n${finding.position.label}\n${finding.continuation}',
                ),
                onTap: () => widget.onOpen(
                  finding.position.games.first,
                  finding.position,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _engineControls() {
    final hunt = widget.hunt;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.m),
      child: Column(
        children: [
          const Text(
            'Check frequent positions for strong replies and unfavourable evaluations. Scores are from this player’s side.',
          ),
          ExpansionTile(
            title: const Text('Engine settings'),
            children: [
              NumberField(
                label: 'Depth',
                value: hunt.depth,
                min: 8,
                max: 30,
                onChanged: (v) {
                  if (!hunt.running) {
                    hunt.depth = v;
                    owner.changed();
                  }
                },
              ),
              NumberField(
                label: 'Positions to check',
                value: hunt.limit,
                min: 1,
                max: 1000,
                step: 25,
                onChanged: (v) {
                  if (!hunt.running) {
                    hunt.limit = v;
                    owner.changed();
                  }
                },
              ),
            ],
          ),
          FilledButton.icon(
            onPressed: owner.busy
                ? null
                : hunt.running
                ? hunt.stop
                : hunt.start,
            icon: Icon(hunt.running ? Icons.stop : Icons.analytics_outlined),
            label: Text(
              hunt.running
                  ? 'Stop · ${hunt.done} / ${hunt.total}'
                  : 'Analyze with engine',
            ),
          ),
          if (hunt.running) const LinearProgressIndicator(),
          if (hunt.error != null)
            Text(
              hunt.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (!hunt.running && hunt.total > 0)
            Text(
              '${hunt.done} positions checked · ${hunt.findings.length} findings',
            ),
        ],
      ),
    );
  }
}
