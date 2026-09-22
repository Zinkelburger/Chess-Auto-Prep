import '../ui/app_action.dart';
import '../ui/pane_tabs.dart';

/// The tabs of the reading card: the moves, which are always there, the
/// trainer, the opponent's replies, the explorer, the tree of the user's
/// own repertoires, and the puzzle being solved. A new thing the card can show is a new value here, and the
/// compiler then asks for its arm in the card's body; the strip, the keys
/// and the Actions menu know nothing about which tabs there are.
enum WorkspaceTab {
  moves('Moves', pinned: true),
  train('Train'),
  replies('Replies'),
  explorer('Explorer'),
  tree('Tree'),
  puzzle('Puzzle');

  const WorkspaceTab(this.title, {this.pinned = false});

  final String title;
  final bool pinned;

  PaneTab<WorkspaceTab> get tab => PaneTab(this, title, pinned: pinned);
}

/// The card's tabs as the Repertoire builder starts: all but the puzzle
/// open, moves up. Training, the replies and the explorer are what a
/// repertoire is for, so they are there from the start and closed by
/// whoever is only reading.
PaneTabs<WorkspaceTab> newWorkspaceTabs() => PaneTabs(
  [
    for (final tab in WorkspaceTab.values)
      if (tab != WorkspaceTab.puzzle) tab.tab,
  ],
  open: const [
    WorkspaceTab.train,
    WorkspaceTab.replies,
    WorkspaceTab.explorer,
    WorkspaceTab.tree,
  ],
);

/// The card's tabs as the PGN Viewer and Study start: the moves, the
/// explorer and the tree. The repertoire's tabs can be shown from the Actions menu.
PaneTabs<WorkspaceTab> readingTabs() => PaneTabs(
  [
    for (final tab in WorkspaceTab.values)
      if (tab != WorkspaceTab.puzzle) tab.tab,
  ],
  open: const [WorkspaceTab.explorer, WorkspaceTab.tree],
);

/// The card's tabs in Tactics: the puzzle first and always there, the game
/// it came from beside it, and the explorer to be shown when wanted. The
/// repertoire's tabs mean nothing here and are not offered.
PaneTabs<WorkspaceTab> puzzleTabs() => PaneTabs(
  const [
    PaneTab(WorkspaceTab.puzzle, 'Puzzle', pinned: true),
    PaneTab(WorkspaceTab.moves, 'Game'),
    PaneTab(WorkspaceTab.explorer, 'Explorer'),
  ],
  open: const [WorkspaceTab.moves],
);

/// The card's tabs as a browser's menu has them: each one that can be
/// closed is shown or closed by name, and the keys that walk them are
/// written beside the entries that take them.
List<AppAction> tabActions(PaneTabs<WorkspaceTab> tabs) => [
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
