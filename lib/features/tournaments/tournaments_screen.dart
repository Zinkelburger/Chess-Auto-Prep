import 'dart:async';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/fen.dart';
import '../../chess/tournament/config.dart';
import '../../chess/tournament/result.dart';
import '../../storage/settings_store.dart';
import '../../storage/tournaments.dart';
import '../../ui/app_icons.dart';
import '../../ui/check_row.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/problem_line.dart';
import '../../ui/theme.dart';
import '../../ui/tool_button.dart';
import 'engine_manager.dart';
import 'history_list.dart';
import 'setup_dialog.dart';
import 'standings_table.dart';
import 'tournament_run.dart';

class TournamentsScreen extends StatefulWidget {
  const TournamentsScreen({
    super.key,
    required this.run,
    required this.position,
    required this.open,
    required this.settings,
  });
  final SettingsStore settings;
  final TournamentRun run;
  final Fen position;
  final void Function(Tournament tournament, int game) open;
  @override
  State<TournamentsScreen> createState() => _ScreenState();
}

class _ScreenState extends State<TournamentsScreen> {
  Tournament? _previewOf;
  Future<TournamentResult<List<String?>>>? _previews;
  TournamentRun get run => widget.run;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([run, widget.settings]),
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
                icon: const Icon(AppIcons.add, size: IconSize.action),
                label: const Text('New tournament…'),
              ),
              TextButton(
                onPressed: () =>
                    unawaited(manageTournamentEngines(context, run)),
                child: const Text('Engines…'),
              ),
              ToolButton(
                icon: AppIcons.refresh,
                tooltip: 'Refresh tournaments',
                onPressed: () => unawaited(run.refresh()),
              ),
              if (run.running)
                OutlinedButton.icon(
                  onPressed: run.stopping ? null : run.stop,
                  icon: const Icon(AppIcons.stop, size: IconSize.action),
                  label: Text(
                    run.stopping ? 'Stopping after this move…' : 'Stop',
                  ),
                ),
              if (run.canRetry && !run.running)
                OutlinedButton(
                  onPressed: () => unawaited(run.retrySave()),
                  child: const Text('Retry save'),
                ),
            ],
          ),
        ),
        if (run.problem case final message?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.m),
            child: ProblemLine(message),
          ),
        for (final warning in run.historyWarnings)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.m),
            child: SelectableText(warning),
          ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 280, child: TournamentHistory(run: run)),
              const VerticalDivider(width: 1),
              Expanded(
                child: run.selected == null
                    ? const SizedBox.shrink()
                    : _details(run.selected!),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _details(Tournament t) {
    final show = widget.settings.value.tournamentFinalPositions;
    if (!identical(t, _previewOf)) {
      _previewOf = t;
      _previews = null;
    }
    if (show &&
        _previews == null &&
        t.games.isNotEmpty &&
        run.store is TournamentPreviews) {
      _previews = (run.store as TournamentPreviews).positions(t.id);
    }
    return FutureBuilder<TournamentResult<List<String?>>>(
      future: show ? _previews : null,
      builder: (context, snapshot) => _detailScroll(
        t,
        show && snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null,
      ),
    );
  }

  Widget _detailScroll(
    Tournament t,
    TournamentResult<List<String?>>? positions,
  ) => CustomScrollView(
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.all(Space.l),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _summary(t),
              if (positions case TournamentFailed(:final message))
                Text(message),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: Space.l),
        sliver: SliverList.builder(
          itemCount: t.games.length,
          itemBuilder: (context, index) =>
              _game(t, t.games[index], switch (positions) {
                TournamentSaved(:final value) when index < value.length =>
                  value[index],
                _ => null,
              }),
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
            child: const Text('Run again…'),
          ),
          ToolButton(
            icon: AppIcons.delete,
            tooltip: 'Delete tournament…',
            onPressed: run.running || run.canRetry
                ? null
                : () => unawaited(_remove(t)),
          ),
        ],
      ),
      Text('${t.status} · ${t.games.length}/${t.config.gameCount} games'),
      Text('${t.config.timeLabel} · ${t.config.formatLabel}'),
      if (t.error case final error?) SelectableText(error),
      const SizedBox(height: Space.m),
      if ((run.activeId == t.id ? run.live : null) case final live?) ...[
        Text(
          'Game ${live.pairing.index + 1} · ${live.plies} '
          '${live.plies == 1 ? 'ply' : 'plies'} · ${live.move}',
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
      TournamentStandingsTable(tournament: t),
      CheckRow(
        label: 'Show final positions',
        value: widget.settings.value.tournamentFinalPositions,
        onChanged: (value) => unawaited(
          widget.settings.update(
            widget.settings.value.copyWith(tournamentFinalPositions: value),
          ),
        ),
      ),
      TextButton.icon(
        onPressed: t.games.isEmpty ? null : () => widget.open(t, 0),
        icon: const Icon(AppIcons.openElsewhere, size: IconSize.action),
        label: const Text('Browse games'),
      ),
      SelectableText(
        run.store.games(t.id).path,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: Space.l),
    ],
  );
  Widget _game(Tournament t, TournamentGame g, String? fen) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s),
    child: Row(
      children: [
        if (fen != null)
          StaticChessboard(
            size: 92,
            orientation: Side.white,
            fen: fen,
            settings: BoardTheme.of(context).previewSettings,
          ),
        if (fen != null) const SizedBox(width: Space.m),
        Expanded(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${g.index + 1}. ${g.whiteName} — ${g.blackName}'),
            subtitle: Text(
              '${g.result} · ${_ending(g.termination)}${g.detail.isEmpty ? "" : " · ${g.detail}"}',
            ),
            trailing: const Icon(AppIcons.openElsewhere),
            onTap: () => widget.open(t, g.index),
          ),
        ),
      ],
    ),
  );
  Future<void> _new([TournamentConfig? previous]) =>
      newTournament(context, run, widget.position, previous: previous);

  Future<void> _remove(Tournament t) async {
    if (await confirmAction(
      context,
      title: 'Delete tournament “${t.config.name}”?',
      message: 'Its games go to the tournament trash.',
      confirm: 'Delete',
    )) {
      await run.remove(t);
    }
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

/// The setup for a tournament, then its run: from the page's button, its
/// `Run again…` with the last one's settings, or the Actions menu.
Future<void> newTournament(
  BuildContext context,
  TournamentRun run,
  Fen position, {
  TournamentConfig? previous,
}) async {
  final config = await tournamentSetup(
    context,
    engines: run.engines,
    position: position,
    previous: previous,
  );
  if (!context.mounted || config == null) return;
  unawaited(run.start(config));
}
