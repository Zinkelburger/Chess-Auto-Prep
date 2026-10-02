import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/players/download_range.dart';
import '../../chess/players/player.dart';
import '../../ui/choice_dialog.dart';
import '../../ui/row_actions.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'analysis_filters.dart';
import 'analysis_rows.dart';
import 'download_dialog.dart';
import 'findings_view.dart';
import 'player_analysis.dart';
import 'player_dialogs.dart';
import 'player_games.dart';
import 'player_hunt.dart';
import 'player_picker.dart';
import 'players.dart';

/// The Player analysis column: who is being prepared for and where their
/// games stand, the colour they are looked at from, then the search and the
/// filters over the three lists they narrow — positions, games and the
/// engine's findings. A row clicked opens its game on the board.
///
/// Everything under the colour scrolls as one, so opening the filters in a
/// short window never squeezes the list away; the list switch stays in view
/// at the top of it. With nobody chosen the column is the list of saved
/// players.
class AnalysisPanel extends StatefulWidget {
  const AnalysisPanel({
    super.key,
    required this.players,
    required this.analysis,
    required this.hunt,
    required this.onOpen,
    required this.onChoose,
    required this.onImport,
    required this.onDownload,
    required this.onDirectory,
    required this.trailing,
  });
  final Players players;
  final PlayerAnalysis analysis;
  final PlayerHunt hunt;
  final void Function(int game, PlayerPosition? at) onOpen;
  final ValueChanged<Player> onChoose;
  final VoidCallback onImport, onDirectory;
  final void Function(PlayerDownloadRange range) onDownload;
  final Widget trailing;
  @override
  State<AnalysisPanel> createState() => _AnalysisPanelState();
}

class _AnalysisPanelState extends State<AnalysisPanel> {
  late final _search = TextEditingController(text: widget.analysis.query);
  bool _filtersOpen = false;

  /// Whether the findings list shows the ones put aside instead.
  bool _showDismissed = false;

  PlayerAnalysis get owner => widget.analysis;

  @override
  void initState() {
    super.initState();
    owner.addListener(_followQuery);
  }

  @override
  void didUpdateWidget(AnalysisPanel old) {
    super.didUpdateWidget(old);
    if (old.analysis != widget.analysis) {
      old.analysis.removeListener(_followQuery);
      owner.addListener(_followQuery);
      _followQuery();
    }
  }

  @override
  void dispose() {
    owner.removeListener(_followQuery);
    _search.dispose();
    super.dispose();
  }

  /// Another player chosen clears the search; the box says so.
  void _followQuery() {
    if (owner.query.isEmpty && _search.text.isNotEmpty) _search.clear();
  }

  Future<void> _choose() async {
    final player = await showChoiceDialog<Player>(
      context,
      title: 'Choose a player',
      options: widget.players.players,
      label: (p) => p.name,
      hint: 'Search players',
      empty: 'No players saved. Add a player first.',
    );
    if (player != null && mounted) widget.onChoose(player);
  }

  Future<void> _add() async {
    final player = await editPlayer(context, widget.players);
    if (player != null && mounted) widget.onChoose(player);
  }

  Future<void> _getGames(Player player) async {
    final range = await downloadRange(context, player);
    if (range != null && mounted) widget.onDownload(range);
  }

  void _toggleFilters() {
    if (mounted) setState(() => _filtersOpen = !_filtersOpen);
  }

  void _dismissedShown(bool shown) {
    if (mounted) setState(() => _showDismissed = shown);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([owner, widget.players, widget.hunt]),
    builder: (context, _) {
      final player = owner.player;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            name: player?.name,
            actions: [
              if (player != null)
                _menu(player)
              else if (widget.players.players.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.add, size: IconSize.action),
                  tooltip: 'Add player',
                  onPressed: _add,
                  visualDensity: VisualDensity.compact,
                ),
            ],
            trailing: widget.trailing,
          ),
          Expanded(
            child: player == null
                ? PlayerPicker(
                    players: widget.players,
                    onChoose: widget.onChoose,
                    onAdd: _add,
                    onDirectory: widget.onDirectory,
                  )
                : _chosen(player),
          ),
        ],
      );
    },
  );

  /// What can be done about the player and their games, out of the way of
  /// the lists: none of it is needed to read them.
  Widget _menu(Player player) => RowActions(
    tooltip: 'Player actions',
    children: [
      MenuItemButton(onPressed: _choose, child: const Text('Change player…')),
      // Only a player with an account has games to download.
      if (player.accounts.isNotEmpty)
        MenuItemButton(
          onPressed: owner.busy ? null : () => unawaited(_getGames(player)),
          child: const Text('Get games…'),
        ),
      MenuItemButton(
        onPressed: owner.busy ? null : widget.onImport,
        child: const Text('Add PGN…'),
      ),
      MenuItemButton(
        onPressed: owner.busy ? null : () => unawaited(owner.select(player)),
        child: const Text('Reload saved games'),
      ),
      MenuItemButton(
        onPressed: widget.onDirectory,
        child: const Text('Players & prep'),
      ),
    ],
  );

  Widget _chosen(Player player) {
    final corpus = owner.corpus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Status(analysis: owner),
        if (corpus != null && corpus.games.isEmpty)
          _NoGames(
            canDownload: player.accounts.isNotEmpty,
            onDownload: () => unawaited(_getGames(player)),
            onImport: widget.onImport,
          ),
        if (corpus != null && corpus.games.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.s),
            child: SegmentedButton<Side>(
              segments: const [
                ButtonSegment(value: Side.white, label: Text('As White')),
                ButtonSegment(value: Side.black, label: Text('As Black')),
              ],
              selected: {owner.side},
              showSelectedIcon: false,
              style: _segments,
              onSelectionChanged: (v) => owner.setSide(v.single),
            ),
          ),
          Expanded(child: _lists(player)),
        ],
      ],
    );
  }

  Widget _lists(Player player) {
    final shown = owner.gameIndexes;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.m),
            child: SearchField(
              controller: _search,
              hint: 'Search games',
              onChanged: owner.search,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _CountLine(
            games: shown.length,
            filters: AnalysisFilters.active(owner),
            filtersOpen: _filtersOpen,
            onFilters: _toggleFilters,
          ),
        ),
        if (_filtersOpen)
          SliverToBoxAdapter(child: AnalysisFilters(analysis: owner)),
        SliverPersistentHeader(
          pinned: true,
          delegate: _ListSwitch(
            list: owner.list,
            onChanged: (list) => owner.configure(list: list),
            color: Theme.of(context).colorScheme.surface,
          ),
        ),
        ...switch (owner.list) {
          PlayerList.openings => _positions(),
          PlayerList.games => _games(shown),
          PlayerList.weaknesses => _findings(player),
        },
      ],
    );
  }
}

extension on _AnalysisPanelState {
  List<Widget> _positions() {
    final positions = owner.positions.take(100).toList();
    final unranked =
        owner.order == PositionOrder.badEval && owner.evals.isEmpty;
    return [
      SliverToBoxAdapter(child: PositionsHeader(analysis: owner)),
      if (unranked)
        SliverToBoxAdapter(
          child: ListMessage(
            'No position has an engine evaluation yet.',
            action: TextButton(
              onPressed: () => owner.configure(list: PlayerList.weaknesses),
              child: const Text('Run engine analysis to rank evaluations'),
            ),
          ),
        )
      else if (positions.isEmpty)
        const SliverToBoxAdapter(
          child: ListMessage(
            'No positions match. Try the other colour or loosen the filters.',
          ),
        )
      else
        SliverList.builder(
          itemCount: positions.length,
          itemBuilder: (context, i) => PositionRow(
            position: positions[i],
            eval: owner.evals[positions[i].key],
            onOpen: () => widget.onOpen(positions[i].games.first, positions[i]),
          ),
        ),
    ];
  }

  List<Widget> _games(List<int> indexes) => [
    if (indexes.isEmpty)
      const SliverToBoxAdapter(
        child: ListMessage(
          'No games match. Try the other colour or loosen the filters.',
        ),
      )
    else
      SliverFixedExtentList.builder(
        itemExtent: puzzleRowHeight,
        itemCount: indexes.length,
        itemBuilder: (context, i) => PlayerGameRow(
          game: owner.corpus!.games[indexes[i]],
          onOpen: () => widget.onOpen(indexes[i], null),
        ),
      ),
  ];

  List<Widget> _findings(Player player) {
    final hunt = widget.hunt;
    final aside = widget.players.dismissedFindings(player.id);
    final shown = [
      for (final f in hunt.findings)
        if (aside.contains(f.key) == _showDismissed) f,
    ];
    return [
      SliverToBoxAdapter(
        child: EngineRun(
          analysis: owner,
          hunt: hunt,
          dismissed: hunt.findings.where((f) => aside.contains(f.key)).length,
          showDismissed: _showDismissed,
          onShowDismissed: _dismissedShown,
        ),
      ),
      SliverList.builder(
        itemCount: shown.length,
        itemBuilder: (context, i) => FindingRow(
          finding: shown[i],
          dismissed: _showDismissed,
          onOpen: () =>
              widget.onOpen(shown[i].position.games.first, shown[i].position),
          onToggle: widget.players.busy
              ? null
              : () => unawaited(
                  _showDismissed
                      ? widget.players.restoreFinding(player.id, shown[i].key)
                      : widget.players.dismissFinding(player.id, shown[i].key),
                ),
        ),
      ),
    ];
  }
}

/// A switch in the column, as small as the rows under it.
const _segments = ButtonStyle(
  visualDensity: VisualDensity.compact,
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Space.xs)),
);

/// The mode's name, or the chosen player's, with the column's actions and
/// the host's toggle in the corner.
class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.actions,
    required this.trailing,
  });

  final String? name;
  final List<Widget> actions;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, Space.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name ?? 'Player analysis',
              style: name == null ? text.labelSmall : text.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ...actions,
          trailing,
        ],
      ),
    );
  }
}

/// Where the player's games stand: how many and how fresh, what is being
/// read or downloaded with the way to stop it, and anything that went wrong.
class _Status extends StatelessWidget {
  const _Status({required this.analysis});

  final PlayerAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wrong = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.error,
    );
    final status = analysis.status;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (analysis.busy) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    status ?? '',
                    style: theme.textTheme.labelSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: analysis.cancel,
                  child: const Text('Cancel'),
                ),
              ],
            ),
            const LinearProgressIndicator(minHeight: progressLineHeight),
          ] else if (status != null)
            Text(status, style: theme.textTheme.labelSmall),
          if (analysis.error case final error?) ...[
            Text(error, style: wrong),
            Wrap(
              spacing: Space.s,
              children: [
                TextButton(
                  onPressed: analysis.busy ? null : analysis.retry,
                  child: const Text('Try again'),
                ),
                if (analysis.errorDetail case final detail?)
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Problem details'),
                        content: SingleChildScrollView(
                          child: SelectableText(detail),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('Details'),
                  ),
              ],
            ),
          ],
          for (final warning in analysis.warnings) Text(warning, style: wrong),
        ],
      ),
    );
  }
}

/// A player with no games yet: the two ways to get some.
class _NoGames extends StatelessWidget {
  const _NoGames({
    required this.canDownload,
    required this.onDownload,
    required this.onImport,
  });

  /// Whether the player has an account to download from.
  final bool canDownload;
  final VoidCallback onDownload;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Space.m),
    child: Wrap(
      spacing: Space.s,
      runSpacing: Space.s,
      children: [
        if (canDownload)
          FilledButton(onPressed: onDownload, child: const Text('Get games')),
        if (canDownload)
          OutlinedButton(onPressed: onImport, child: const Text('Add PGN…'))
        else
          FilledButton(onPressed: onImport, child: const Text('Add PGN…')),
      ],
    ),
  );
}

/// How many games the colour, the search and the filters let through, with
/// the way to the filters beside it.
class _CountLine extends StatelessWidget {
  const _CountLine({
    required this.games,
    required this.filters,
    required this.filtersOpen,
    required this.onFilters,
  });

  final int games;

  /// How many filters are on.
  final int filters;
  final bool filtersOpen;
  final VoidCallback onFilters;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.xs, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '$games ${games == 1 ? 'game' : 'games'}',
            style: Theme.of(context).textTheme.labelSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton.icon(
          onPressed: onFilters,
          icon: Icon(
            filtersOpen ? Icons.expand_less : Icons.expand_more,
            size: IconSize.action,
          ),
          iconAlignment: IconAlignment.end,
          label: Text(filters == 0 ? 'Filters' : 'Filters ($filters)'),
        ),
      ],
    ),
  );
}

/// Positions, Games or Findings: which list is under the search. It stays
/// at the top of the column while its list scrolls under it.
class _ListSwitch extends SliverPersistentHeaderDelegate {
  const _ListSwitch({
    required this.list,
    required this.onChanged,
    required this.color,
  });

  final PlayerList list;
  final ValueChanged<PlayerList> onChanged;

  /// The column's own colour, so the rows pass under the switch unseen.
  final Color color;

  @override
  double get minExtent => trainRowHeight;

  @override
  double get maxExtent => trainRowHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      // Exactly the height the header says it has: a pinned header whose
      // child is shorter than its extent is laid out wrongly.
      SizedBox(
        height: maxExtent,
        child: ColoredBox(
          color: color,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.m),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<PlayerList>(
                  showSelectedIcon: false,
                  style: _segments,
                  segments: const [
                    ButtonSegment(
                      value: PlayerList.openings,
                      label: Text('Positions'),
                    ),
                    ButtonSegment(
                      value: PlayerList.games,
                      label: Text('Games'),
                    ),
                    ButtonSegment(
                      value: PlayerList.weaknesses,
                      label: Text('Findings'),
                    ),
                  ],
                  selected: {list},
                  onSelectionChanged: (v) => onChanged(v.single),
                ),
              ],
            ),
          ),
        ),
      );

  @override
  bool shouldRebuild(_ListSwitch old) => old.list != list || old.color != color;
}
