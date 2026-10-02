import '../storage/settings_store.dart';
import '../workspace/fill_gaps.dart';
import '../workspace/fill_states.dart';
import '../workspace/action_layout.dart';
import '../workspace/workspace_tabs.dart';
import 'workspace_requests.dart';

/// The way into a search from outside the Search tab — the Actions entry
/// and Ctrl+G: the tab comes up and the search starts with the numbers it
/// last had, the Replies tab's rating and the tab's depth.
final class SearchDoor {
  SearchDoor({
    required this.fill,
    required this.settings,
    required this.requests,
  });

  final FillGaps fill;
  final SettingsStore settings;
  final WorkspaceRequests requests;

  /// What refused the search goes in the bar. A mode without a Search tab
  /// (Tactics, My games) starts nothing: the search would run where it
  /// cannot be seen or stopped, with the engine pane paused for it.
  Future<void> search(ActionLayout layout) async {
    if (!fill.canStart) return;
    if (!layout.pane(0).tabs.any((tab) => tab.id == WorkspaceTab.search)) {
      return;
    }
    layout.reveal(WorkspaceTab.search);
    final refusal = await fill.resume(
      FillRequest.of(settings.value),
      orAfresh: true,
    );
    if (refusal != null) requests.say(refusal);
  }
}
