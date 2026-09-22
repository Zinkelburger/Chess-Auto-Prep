import '../ui/pane_tabs.dart';

/// The tabs of the reading card, by name: the moves, which are always
/// there, the opponent's replies, and the explorer. A new thing the card
/// can show is a new entry here and a new arm in the card's body; the
/// strip, the keys and the Actions menu know nothing about which tabs
/// there are.
abstract final class WorkspaceTab {
  static const moves = PaneTab('moves', 'Moves', pinned: true);
  static const replies = PaneTab('replies', 'Replies');
  static const explorer = PaneTab('explorer', 'Explorer');

  static const all = [moves, replies, explorer];
}

/// The card's tabs as a window starts: all three open, moves up. The old
/// viewer started with its reader alone; here the replies and the explorer
/// are what building a repertoire is about, so they are there from the
/// start and closed by whoever is only reading.
PaneTabs newWorkspaceTabs() => PaneTabs(
  WorkspaceTab.all,
  open: [WorkspaceTab.replies.id, WorkspaceTab.explorer.id],
);
