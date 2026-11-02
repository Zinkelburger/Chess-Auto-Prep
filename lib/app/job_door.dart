import '../features/tournaments/tournament_run.dart';
import '../workspace/analysis/engine_jobs.dart';
import '../workspace/workspace_tabs.dart';
import 'mode.dart';
import 'mode_view.dart';
import 'workspace_requests.dart';

/// The way back to the engine job the top bar names: the mode it was
/// started in, with the tab that shows it up, or the tournament that runs.
final class JobDoor {
  JobDoor({
    required this.jobs,
    required this.requests,
    required this.views,
    this.tournaments,
  });

  final EngineJobs? jobs;
  final WorkspaceRequests requests;
  final Map<Mode, ModeView> views;
  final TournamentRun? tournaments;

  Mode? _jobMode;
  EngineJobKind? _jobKind;

  /// Notes the mode on screen when a job starts: the one to go back to.
  void changed() {
    final kind = jobs?.activeKind;
    if (kind != _jobKind) {
      _jobKind = kind;
      _jobMode = kind == null ? null : requests.mode;
    }
  }

  void show() {
    final kind = jobs?.activeKind;
    if (kind == null) return;
    if (kind == EngineJobKind.tournament) {
      requests.switchTo(Mode.engineTournament);
      final run = tournaments;
      final active = run?.history
          .where((t) => t.id == run.activeId)
          .firstOrNull;
      if (active != null) run!.select(active);
      return;
    }
    final tab = switch (kind) {
      EngineJobKind.search || EngineJobKind.makingLines => WorkspaceTab.search,
      EngineJobKind.audit => WorkspaceTab.audit,
      EngineJobKind.solitaire => WorkspaceTab.solitaire,
      _ => WorkspaceTab.review,
    };
    var mode = _jobMode ?? Mode.repertoires;
    if (!views[mode]!.layout.pane(0).tabs.any((t) => t.id == tab)) {
      mode = Mode.repertoires;
    }
    requests.switchTo(mode);
    views[mode]!.layout.reveal(tab);
  }
}
