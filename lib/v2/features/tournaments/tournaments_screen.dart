import 'dart:async';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/fen.dart';
import '../../chess/tournament/config.dart';
import '../../chess/tournament/result.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'engine_manager.dart';
import 'setup_dialog.dart';
import 'tournament_run.dart';

class TournamentsScreen extends StatefulWidget {
  const TournamentsScreen({
    super.key,
    required this.run,
    required this.position,
    required this.open,
  });
  final TournamentRun run;
  final Fen position;
  final void Function(Tournament tournament, int game) open;
  @override
  State<TournamentsScreen> createState() => _ScreenState();
}

class _ScreenState extends State<TournamentsScreen> {
  String _query = '';
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  TournamentRun get run => widget.run;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: run,
    builder: (context, _) => Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(Space.m),
          child: Wrap(
            spacing: Space.s,
            runSpacing: Space.s,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Engine tournament',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              FilledButton.icon(
                onPressed: run.running || run.canRetry
                    ? null
                    : () => unawaited(_new()),
                icon: const Icon(Icons.add),
                label: const Text('New tournament'),
              ),
              TextButton(
                onPressed: () =>
                    unawaited(manageTournamentEngines(context, run)),
                child: const Text('Engines'),
              ),
              IconButton(
                tooltip: 'Refresh tournaments',
                onPressed: () => unawaited(run.refresh()),
                icon: const Icon(Icons.refresh),
              ),
              if (run.running)
                OutlinedButton(
                  onPressed: run.stopping ? null : run.stop,
                  child: Text(
                    run.stopping ? 'Stopping after this move…' : 'Stop',
                  ),
                ),
              if (run.canRetry && !run.running)
                FilledButton(
                  onPressed: () => unawaited(run.retrySave()),
                  child: const Text('Retry save'),
                ),
            ],
          ),
        ),
        if (run.problem case final message?)
          Padding(
            padding: const EdgeInsets.all(Space.s),
            child: SelectableText(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 280, child: _history()),
              const VerticalDivider(width: 1),
              Expanded(
                child: run.selected == null
                    ? const Center(child: Text('No tournaments yet'))
                    : _details(run.selected!),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _history() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(Space.s),
        child: SearchField(
          controller: _search,
          hint: 'Search tournaments',
          onChanged: (value) {
            if (mounted) setState(() => _query = value.toLowerCase());
          },
        ),
      ),
      Expanded(
        child: ListView(
          children: [
            for (final t in run.history.where(
              (t) =>
                  '${t.config.name} ${t.config.engines.map((e) => e.name).join(" ")}'
                      .toLowerCase()
                      .contains(_query),
            ))
              ListTile(
                selected: run.selected?.id == t.id,
                title: Text(t.config.name),
                subtitle: Text(
                  '${t.status} · ${t.games.length}/${t.config.gameCount} games',
                ),
                onTap: () => run.select(t),
              ),
          ],
        ),
      ),
    ],
  );
  Widget _details(Tournament t) => CustomScrollView(
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.all(Space.l),
        sliver: SliverToBoxAdapter(child: _summary(t)),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: Space.l),
        sliver: SliverList.builder(
          itemCount: t.games.length,
          itemBuilder: (context, index) => _game(t, t.games[index]),
        ),
      ),
    ],
  );

  Widget _summary(Tournament t) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              t.config.name,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          TextButton(
            onPressed: run.running || run.canRetry
                ? null
                : () => unawaited(_new(t.config)),
            child: const Text('Run again'),
          ),
          IconButton(
            tooltip: 'Move tournament to trash',
            onPressed: run.running || run.canRetry
                ? null
                : () => unawaited(_remove(t)),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      Text('${t.status} · ${t.games.length}/${t.config.gameCount} games'),
      const SizedBox(height: Space.m),
      if ((run.activeId == t.id ? run.live : null) case final live?) ...[
        Text(
          'Game ${live.pairing.index + 1} · ${live.plies} plies · ${live.move}',
        ),
        const SizedBox(height: Space.s),
        StaticChessboard(
          size: 280,
          orientation: Side.white,
          fen: live.fen.value,
          settings: BoardTheme.of(context).previewSettings,
        ),
        const SizedBox(height: Space.m),
      ],
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Engine')),
            DataColumn(label: Text('Points'), numeric: true),
            DataColumn(label: Text('W'), numeric: true),
            DataColumn(label: Text('D'), numeric: true),
            DataColumn(label: Text('L'), numeric: true),
          ],
          rows: [
            for (final s in t.scores)
              DataRow(
                cells: [
                  DataCell(Text(s.name)),
                  DataCell(Text(s.points.toStringAsFixed(1))),
                  DataCell(Text('${s.wins}')),
                  DataCell(Text('${s.draws}')),
                  DataCell(Text('${s.losses}')),
                ],
              ),
          ],
        ),
      ),
      const SizedBox(height: Space.l),
    ],
  );
  Widget _game(Tournament t, TournamentGame g) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text('${g.index + 1}. ${g.whiteName} — ${g.blackName}'),
    subtitle: Text(
      '${g.result} · ${_ending(g.termination)}${g.detail.isEmpty ? "" : " · ${g.detail}"}',
    ),
    trailing: const Icon(Icons.open_in_new),
    onTap: () => widget.open(t, g.index),
  );
  Future<void> _new([TournamentConfig? previous]) async {
    final config = await tournamentSetup(
      context,
      engines: run.engines,
      position: widget.position,
      previous: previous,
    );
    if (!mounted || config == null) return;
    unawaited(run.start(config));
  }

  Future<void> _remove(Tournament t) async {
    if (await confirmAction(
      context,
      title: 'Move tournament to trash',
      message: 'Move ${t.config.name} and its games to the tournament trash?',
      confirm: 'Move to trash',
    ))
      await run.remove(t);
  }
}

String _ending(String reason) => switch (reason) {
  'checkmate' => 'Checkmate',
  'stalemate' => 'Stalemate',
  'insufficientMaterial' => 'Insufficient material',
  'fiftyMoveRule' => 'Fifty-move rule',
  'threefoldRepetition' => 'Threefold repetition',
  'drawAdjudication' => 'Draw adjudication',
  'resignAdjudication' => 'Resignation adjudication',
  'maxMoves' => 'Move limit',
  'timeForfeit' => 'Time forfeit',
  'illegalMove' => 'Illegal move',
  'engineFailure' => 'Engine failure',
  'aborted' => 'Stopped',
  _ => reason,
};
