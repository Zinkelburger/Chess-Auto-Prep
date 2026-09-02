/// Engine Tournament mode: run engine-vs-engine matches and read the results.
///
/// The games are plain PGN in `Documents/engine_tournaments/<name>/games.pgn`,
/// which is what makes the last mile cheap — clicking a row in the games
/// table hands that file to the PGN Viewer with a game number, and the
/// viewer's own Prev/Next then walks the whole match.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_messages.dart';
import '../../../widgets/app_breadcrumb_trail.dart';
import '../../../widgets/app_mode_switcher.dart';
import '../../../widgets/app_overflow_menu.dart';
import '../../../widgets/app_settings_button.dart';
import '../../../widgets/layout/responsive_split_layout.dart';
import '../controllers/engine_tournament_controller.dart';
import '../models/stored_tournament.dart';
import '../models/tournament_config.dart';
import '../models/tournament_game.dart';
import 'engine_manager_dialog.dart';
import 'new_tournament_dialog.dart';
import 'tournament_detail_pane.dart';
import 'tournament_list_pane.dart';

class EngineTournamentScreen extends StatefulWidget {
  const EngineTournamentScreen({super.key, this.controller});

  /// Controller to use instead of making one.
  ///
  /// Only tests pass this. A `testWidgets` body runs in a fake-async zone
  /// where the controller's own directory scan never completes, so the test
  /// initialises one itself under `runAsync` and hands it over ready.
  @visibleForTesting
  final EngineTournamentController? controller;

  @override
  State<EngineTournamentScreen> createState() => _EngineTournamentScreenState();
}

class _EngineTournamentScreenState extends State<EngineTournamentScreen> {
  late final EngineTournamentController _controller =
      widget.controller ?? EngineTournamentController();

  /// Only dispose what this screen created.
  late final bool _ownsController = widget.controller == null;

  AppState? _appState;

  @override
  void initState() {
    super.initState();
    if (_ownsController) unawaited(_controller.initialize());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      _appState = appState;
      appState.addListener(_onAppStateChanged);
      _consumeHandoff(appState);
    });
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _onAppStateChanged() {
    final appState = _appState;
    if (appState == null || appState.currentMode != AppMode.engineTournament) {
      return;
    }
    _consumeHandoff(appState);
  }

  /// Arriving with a tournament named — from a breadcrumb, or from an agent's
  /// open request — selects it, re-reading from disk first because the run
  /// that produced it may have finished outside this screen's knowledge.
  void _consumeHandoff(AppState appState) {
    final handoff = appState.takeHandoff<OpenEngineTournament>();
    if (handoff == null) return;
    unawaited(_selectById(handoff.tournamentId));
  }

  Future<void> _selectById(String? id) async {
    await _controller.refresh();
    if (!mounted || id == null) return;
    final match = _controller.tournaments.where((t) => t.id == id).firstOrNull;
    if (match == null) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'No tournament called "$id" under Documents/engine_tournaments.',
      );
      return;
    }
    _controller.select(match);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final selected = _controller.selected;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: const AppBarTitleWithTrail(title: AppModeSwitcher()),
            actions: [
              FilledButton.icon(
                onPressed: _controller.isRunning ? null : _newTournament,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New tournament'),
              ),
              const SizedBox(width: 8),
              AppOverflowMenu(
                entries: [
                  AppMenuEntry(
                    label: 'Engines…',
                    icon: Icons.memory,
                    onRun: _manageEngines,
                  ),
                  AppMenuEntry(
                    label: 'Refresh',
                    icon: Icons.refresh,
                    enabled: !_controller.isRunning,
                    onRun: () => unawaited(_controller.refresh()),
                  ),
                  AppMenuEntry(
                    label: 'App settings…',
                    icon: Icons.settings_outlined,
                    dividerAbove: true,
                    onRun: () => unawaited(openAppSettings(context)),
                  ),
                ],
              ),
            ],
          ),
          body: _buildBody(selected),
        );
      },
    );
  }

  Widget _buildBody(StoredTournament? selected) {
    if (_controller.isLoading && _controller.tournaments.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_controller.error != null && _controller.tournaments.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _controller.error!,
            style: AppTextStyles.body.copyWith(color: AppColors.danger),
          ),
        ),
      );
    }
    if (_controller.tournaments.isEmpty) {
      return TournamentEmptyState(onNew: _newTournament);
    }
    return ResponsiveSplitLayout(
      primaryFlex: 3,
      secondaryFlex: 7,
      primary: TournamentListPane(
        tournaments: _controller.tournaments,
        selectedId: selected?.id,
        runningId: _controller.runningId,
        onSelect: _controller.select,
        onNew: _newTournament,
      ),
      secondary: selected == null
          ? TournamentEmptyState(onNew: _newTournament)
          : TournamentDetailPane(
              controller: _controller,
              tournament: selected,
              onOpenGame: (game) => _openInViewer(selected, game),
              onOpenAllGames: () => _openInViewer(selected, null),
              onDelete: () => unawaited(_delete(selected)),
              onRerun: () => unawaited(_start(selected.config)),
            ),
    );
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _newTournament() async {
    final appState = context.read<AppState>();
    final config = await showNewTournamentDialog(
      context,
      engines: _controller.engines,
      boardFen: appState.currentPosition.fen,
      onManageEngines: _manageEngines,
    );
    if (config == null) return;
    await _start(config);
  }

  Future<void> _start(TournamentConfig config) async {
    if (_controller.isRunning) return;
    final finished = await _controller.start(config);
    if (!mounted || finished == null) return;
    final message = switch (finished.status) {
      TournamentStatus.completed =>
        '${config.name}: ${finished.gamesPlayed} games played.',
      TournamentStatus.cancelled =>
        '${config.name} stopped after ${finished.gamesPlayed} games.',
      _ => '${config.name} failed: ${finished.error ?? "unknown error"}',
    };
    showAppSnackBar(context, message);
  }

  Future<void> _manageEngines() async {
    await showEngineManagerDialog(context, _controller);
  }

  Future<void> _delete(StoredTournament tournament) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${tournament.config.name}"?'),
        content: const Text(
          'The games and the crosstable go with it. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _controller.delete(tournament.id);
  }

  /// Hand the whole match to the PGN Viewer, optionally parked on one game.
  ///
  /// The collection stays loaded there, so Prev/Next walk every game of the
  /// tournament — which is the reason the games are one file rather than one
  /// file each.
  void _openInViewer(StoredTournament tournament, TournamentGameRecord? game) {
    context.read<AppState>().switchToPgnViewer(
      path: tournament.pgnPath,
      gameIndex: game?.gameIndex,
      historyLabel: game == null
          ? 'Games: ${tournament.config.name}'
          : '${tournament.config.name} game ${game.gameNumber}',
    );
  }
}
