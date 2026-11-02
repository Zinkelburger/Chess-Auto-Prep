import 'dart:async';
import 'package:flutter/material.dart';

import '../chess/tournament/result.dart';
import '../features/tournaments/engine_manager.dart';
import '../features/tournaments/tournament_run.dart';
import '../features/tournaments/tournaments_screen.dart';
import '../storage/chapter_files.dart';
import '../ui/app_action.dart';
import '../ui/app_icons.dart';
import '../ui/screen_keys.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_tabs.dart';
import 'mode_view.dart';
import 'workspace_requests.dart';

final class TournamentView extends ModeView {
  TournamentView(Workspace workspace, this.run, this.requests)
    : super(workspace, readingTabs());
  final TournamentRun? run;
  final WorkspaceRequests requests;
  @override
  Listenable get changes => run ?? requests;
  @override
  void entered() {
    if (run case final owner?) unawaited(owner.refresh());
  }

  @override
  Widget list(Widget toggle) => const SizedBox.shrink();

  /// The page's own buttons.
  @override
  List<AppAction> actions(ModeMenu menu) => [
    if (run case final run?) ...[
      AppAction(
        'New tournament…',
        run.running || run.canRetry
            ? null
            : () => unawaited(
                newTournament(menu.context, run, workspace.session.cursor.fen),
              ),
        icon: AppIcons.add,
        group: 'Tournaments',
      ),
      AppAction(
        'Engines…',
        () => unawaited(manageTournamentEngines(menu.context, run)),
        group: 'Tournaments',
      ),
      AppAction(
        'Refresh',
        () => unawaited(run.refresh()),
        icon: AppIcons.refresh,
        group: 'Tournaments',
      ),
    ],
  ];
  @override
  Widget screen(Map<ShortcutActivator, VoidCallback> windowKeys) => ScreenKeys(
    bindings: windowKeys,
    child: Focus(
      autofocus: true,
      child: run == null
          ? const Center(child: Text('Tournament storage is unavailable.'))
          : TournamentsScreen(
              run: run!,
              settings: workspace.settings,
              position: workspace.session.cursor.fen,
              open: (t, g) => unawaited(_open(t, g)),
            ),
    ),
  );
  Future<void> _open(Tournament tournament, int game) async {
    final ref = ChapterRef.at(run!.store.games(tournament.id).path);
    await requests.openFile(ref, game: game);
  }
}
