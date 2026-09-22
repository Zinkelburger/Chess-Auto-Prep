import '../ui/app_action.dart';
import '../ui/pane_tabs.dart';

/// The tabs of the reading card, by name: the moves, which are always
/// there, the trainer, the opponent's replies, and the explorer. A new
/// thing the card can show is a new entry here and a new arm in the card's
/// body; the strip, the keys and the Actions menu know nothing about which
/// tabs there are. The trainer's body is a feature's, handed in by the
/// shell.
abstract final class WorkspaceTab {
  static const moves = PaneTab('moves', 'Moves', pinned: true);
  static const train = PaneTab('train', 'Train');
  static const replies = PaneTab('replies', 'Replies');
  static const explorer = PaneTab('explorer', 'Explorer');

  static const all = [moves, train, replies, explorer];
}

/// The card's tabs as a window starts: all open, moves up. The old viewer
/// started with its reader alone; here training, the replies and the
/// explorer are what a repertoire is for, so they are there from the start
/// and closed by whoever is only reading.
PaneTabs newWorkspaceTabs() => PaneTabs(
  WorkspaceTab.all,
  open: [
    WorkspaceTab.train.id,
    WorkspaceTab.replies.id,
    WorkspaceTab.explorer.id,
  ],
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
