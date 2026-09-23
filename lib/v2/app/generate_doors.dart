import 'dart:async';

import 'package:flutter/material.dart';

import '../storage/settings_store.dart';
import '../ui/pane_tabs.dart';
import '../workspace/document_session.dart';
import '../workspace/fill_dialog.dart';
import '../workspace/fill_gaps.dart';
import '../workspace/workspace_tabs.dart';
import 'workspace_requests.dart';

/// The ways into a search from the board and back to what it found: the
/// dialog behind the Actions entry, Ctrl+G and the Prep tab's `Generate…`,
/// and ↑ / ↓ over the Prep tab's rows. On the analysis board the search is `Generate from
/// here…` and plays for the side at the bottom of the board; on a chapter
/// it is `Fill gaps from here…` and plays for the chapter's side.
final class GenerateDoors {
  GenerateDoors({
    required this.fill,
    required this.session,
    required this.settings,
    required this.requests,
  });

  final FillGaps fill;
  final DocumentSession session;
  final SettingsStore settings;
  final WorkspaceRequests requests;

  /// The dialog, then the run with the Prep tab up to watch it; what
  /// refused it goes in the bar.
  Future<void> generate(
    BuildContext context,
    PaneTabs<WorkspaceTab> tabs,
  ) async {
    if (!fill.canStart) return;
    final s = settings.value;
    final onBoard = session.isScratch;
    final request = await showFillDialog(
      context,
      title: onBoard ? 'Generate from here' : 'Fill gaps from here',
      action: onBoard ? 'Generate' : 'Fill',
      side: session.orientation,
      elo: s.opponentElo,
      onceIn: s.coverOnceIn,
    );
    if (request == null || !context.mounted) return;
    if (tabs.tabs.any((tab) => tab.id == WorkspaceTab.prep)) {
      tabs.show(WorkspaceTab.prep);
    }
    final refusal = await fill.start(request);
    if (refusal != null) requests.say(refusal);
  }

  /// Puts the found item at [index] on the board.
  void go(int index) {
    final found = fill.found;
    if (found == null || index < 0 || index >= found.items.length) return;
    fill.pick(index);
    unawaited(requests.showFound(found, index));
  }

  /// The next (or, with [by] −1, the previous) found item; the first one
  /// when none has been gone to yet. Answers whether there was one to take
  /// the key, so ↑ / ↓ keep their other meanings when there is not.
  bool step(int by) {
    final count = fill.found?.items.length ?? 0;
    if (count == 0) return false;
    final picked = fill.picked;
    go(picked == null ? 0 : (picked + by).clamp(0, count - 1));
    return true;
  }
}
