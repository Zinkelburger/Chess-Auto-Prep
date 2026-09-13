import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../models/analysis_player_info.dart';
import '../../../widgets/app_breadcrumb_trail.dart';
import '../../../widgets/app_mode_switcher.dart';
import '../../../widgets/app_overflow_menu.dart';
import '../../../widgets/app_settings_button.dart';
import '../services/opponent_store.dart';
import 'opponent_actions.dart';
import 'people_screen.dart';
import 'tournament_screen.dart';
import 'tournaments_screen.dart';

/// The shared directory and preparation groups, independent of an analysis board.
class PlayersPrepScreen extends StatefulWidget {
  const PlayersPrepScreen({super.key, this.store, this.actions});
  final OpponentStore? store;
  final OpponentActions? actions;

  @override
  State<PlayersPrepScreen> createState() => _PlayersPrepScreenState();
}

class _PlayersPrepScreenState extends State<PlayersPrepScreen> {
  late final _store = widget.store ?? OpponentStore.instance;
  late final _actions = widget.actions ?? OpponentActions(store: _store);
  int _tab = 0;
  String? _groupId;
  int _refreshToken = 0;
  AppState? _app;
  AppMode? _lastMode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppState>();
    if (identical(app, _app)) return;
    _app?.removeListener(_modeChanged);
    _app = app;
    _lastMode = app.currentMode;
    app.addListener(_modeChanged);
  }

  void _modeChanged() {
    final mode = _app!.currentMode;
    final entering = mode == AppMode.playersPrep && mode != _lastMode;
    _lastMode = mode;
    if (mounted && entering) setState(() => _refreshToken++);
  }

  @override
  void dispose() {
    _app?.removeListener(_modeChanged);
    super.dispose();
  }

  Future<void> _openPlayer(AnalysisPlayerInfo player) async {
    if (!mounted) return;
    context.read<AppState>().handOff(OpenPlayerAnalysis(player));
    popToRoot(context);
  }

  void _showGroups() {
    if (mounted) setState(() => _groupId = null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) {
      final group = _store.tournament(_groupId ?? '');
      final showingGroup = _tab == 1 && group != null;
      return Scaffold(
        appBar: AppBar(
          titleSpacing: 16,
          automaticallyImplyLeading: false,
          leading: !showingGroup
              ? null
              : IconButton(
                  key: const Key('prep-back-to-groups'),
                  tooltip: 'Back to groups',
                  onPressed: _showGroups,
                  icon: const Icon(Icons.arrow_back),
                ),
          title: AppBarTitleWithTrail(
            title: Text(
              !showingGroup ? 'Players & prep' : 'Groups / ${group.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          actions: [
            AppOverflowMenu(
              entries: [
                AppMenuEntry(
                  label: 'Player analysis',
                  icon: Icons.person_search,
                  onRun: () {
                    if (!mounted) return;
                    context.read<AppState>().pushMode(
                      AppMode.positionAnalysis,
                      historyLabel: 'Player analysis',
                    );
                  },
                ),
              ],
            ),
            const AppModeSwitcher(),
            const AppSettingsButton(mode: AppMode.playersPrep),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<int>(
                  segments: [
                    ButtonSegment(
                      value: 0,
                      icon: const Icon(Icons.people_outline),
                      label: Text('All players (${_store.people.length})'),
                    ),
                    ButtonSegment(
                      value: 1,
                      icon: const Icon(Icons.folder_shared_outlined),
                      label: Text('Groups (${_store.tournaments.length})'),
                    ),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (value) {
                    if (mounted) setState(() => _tab = value.single);
                  },
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  PeopleScreen(
                    store: _store,
                    actions: _actions,
                    embedded: true,
                    onOpenPlayer: _openPlayer,
                    refreshToken: _refreshToken,
                  ),
                  IndexedStack(
                    index: group == null ? 0 : 1,
                    children: [
                      TournamentsScreen(
                        store: _store,
                        actions: _actions,
                        embedded: true,
                        onOpenGroup: (selected) {
                          if (mounted) setState(() => _groupId = selected.id);
                        },
                      ),
                      if (group != null)
                        TournamentScreen(
                          key: ValueKey(group.id),
                          tournamentId: group.id,
                          store: _store,
                          actions: _actions,
                          embedded: true,
                          onOpenPlayer: _openPlayer,
                          refreshToken: _refreshToken,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
