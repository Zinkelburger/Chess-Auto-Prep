import '../ui/app_action.dart';
import '../ui/pane_tabs.dart';

/// The tabs of the reading card: the moves, which are always there, the
/// trainer, the opponent's replies, the explorer (the user's own book
/// among its sources), the search from the board and its values, the puzzle
/// being solved, and what the user's book says about one of their games. A new thing the card can show is a new value here, and the
/// compiler then asks for its arm in the card's body; the strip, the keys
/// and the Actions menu know nothing about which tabs there are.
enum WorkspaceTab {
  moves('Moves', pinned: true),
  train('Train'),
  replies('Replies'),
  explorer('Explorer'),
  search('Search'),
  puzzle('Puzzle'),
  book('Book');

  const WorkspaceTab(this.title, {this.pinned = false});

  final String title;
  final bool pinned;

  PaneTab<WorkspaceTab> get tab => PaneTab(this, title, pinned: pinned);
}

/// The tabs that mean something with any document on the board; the
/// puzzle and the book verdict belong to their modes.
List<PaneTab<WorkspaceTab>> get _documentTabs => [
  for (final tab in WorkspaceTab.values)
    if (tab != WorkspaceTab.puzzle && tab != WorkspaceTab.book) tab.tab,
];

/// The card's tabs as the Repertoire builder starts: all of the document's
/// open, moves up. Training, the replies and the explorer are what a
/// repertoire is for, so they are there from the start and closed by
/// whoever is only reading.
PaneTabs<WorkspaceTab> newWorkspaceTabs() => PaneTabs(
  _documentTabs,
  open: const [
    WorkspaceTab.train,
    WorkspaceTab.replies,
    WorkspaceTab.explorer,
    WorkspaceTab.search,
  ],
);

/// The card's tabs as the PGN Viewer and Study start: the moves, the
/// explorer and Search, where a search from the board is started.
/// The repertoire's tabs can be shown from the Actions menu.
PaneTabs<WorkspaceTab> readingTabs() => PaneTabs(
  _documentTabs,
  open: const [WorkspaceTab.explorer, WorkspaceTab.search],
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

/// The card's tabs in My games: the book's verdict on the game first and
/// always there, the game beside it, and the explorer, whose Book shows
/// what else the book plays.
PaneTabs<WorkspaceTab> bookTabs() => PaneTabs(
  const [
    PaneTab(WorkspaceTab.book, 'Book', pinned: true),
    PaneTab(WorkspaceTab.moves, 'Game'),
    PaneTab(WorkspaceTab.explorer, 'Explorer'),
  ],
  open: const [WorkspaceTab.moves, WorkspaceTab.explorer],
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
