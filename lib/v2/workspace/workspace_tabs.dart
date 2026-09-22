import '../ui/app_action.dart';
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

/// The card's tabs as a browser's menu has them: each one that can be
/// closed is shown or closed by name, and the keys that walk them are
/// written beside the entries that take them.
List<AppAction> tabActions(PaneTabs tabs) => [
  for (final tab in tabs.tabs)
    if (!tab.pinned)
      tabs.isOpen(tab.id)
          ? AppAction(
              'Close ${tab.title}',
              () => tabs.close(tab.id),
              shortcut: tabs.selected == tab.id ? 'Ctrl+W' : null,
              group: 'Tabs',
            )
          : AppAction(
              'Show ${tab.title}',
              () => tabs.show(tab.id),
              group: 'Tabs',
            ),
  AppAction(
    'Next tab',
    tabs.open.length < 2 ? null : tabs.next,
    shortcut: 'Ctrl+Tab',
    group: 'Tabs',
  ),
];
