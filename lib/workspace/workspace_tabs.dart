import '../ui/app_action.dart';
import '../ui/pane_tabs.dart';
import '../ui/app_keys.dart';
import 'action_layout.dart';

/// The tabs of the reading card: the moves, the
/// trainer, the opponent's replies, the explorer (the user's own book
/// among its sources), the search from the board and its values, the puzzle
/// being solved, what the user's book says about one of their games, and
/// the chapter's audit, and the filter over the open file's games. A new thing the card can show is a new value here, and the
/// compiler then asks for its arm in the card's body; the strip, the keys
/// and the Actions menu know nothing about which tabs there are.
enum WorkspaceTab {
  moves('Moves'),
  analysis('Analysis'),
  review('Game review'),
  solitaire('Solitaire'),
  train('Train'),
  replies('Replies'),
  explorer('Explorer'),
  search('Expectimax'),
  audit('Audit'),
  puzzle('Puzzle'),
  source('Game'),
  book('Book'),
  filter('Filter'),
  player('Player openings'),
  playerBook('My book');

  const WorkspaceTab(this.title);

  final String title;

  PaneTab<WorkspaceTab> get tab => PaneTab(this, title);
}

/// The tabs that mean something with any document on the board; the
/// puzzle and the book verdict belong to their modes.
List<PaneTab<WorkspaceTab>> get _documentTabs => [
  for (final tab in WorkspaceTab.values)
    if (tab != WorkspaceTab.puzzle &&
        tab != WorkspaceTab.source &&
        tab != WorkspaceTab.book &&
        tab != WorkspaceTab.filter &&
        tab != WorkspaceTab.solitaire &&
        tab != WorkspaceTab.player &&
        tab != WorkspaceTab.playerBook)
      tab.tab,
];

/// Builder starts with its building tools. Training remains opt-in.
PaneTabs<WorkspaceTab> newWorkspaceTabs() => PaneTabs(
  _documentTabs,
  open: const [WorkspaceTab.moves, WorkspaceTab.explorer, WorkspaceTab.search],
  selected: WorkspaceTab.search,
);

/// The card's tabs as the PGN Viewer and Study start: the moves, the
/// explorer.
/// Repertoire operations stay in the builder.
PaneTabs<WorkspaceTab> readingTabs() => PaneTabs(
  [
    WorkspaceTab.moves.tab,
    WorkspaceTab.explorer.tab,
    WorkspaceTab.analysis.tab,
    WorkspaceTab.review.tab,
  ],
  open: const [WorkspaceTab.moves, WorkspaceTab.explorer, WorkspaceTab.review],
);

/// The PGN Viewer's tabs. A file opens as a book does, on its moves alone;
/// the explorer, the engine's review, Solitaire, what the user's books say
/// about the game and the filter over the file's games are opened when
/// wanted.
PaneTabs<WorkspaceTab> viewerTabs() => PaneTabs(
  [
    WorkspaceTab.moves.tab,
    WorkspaceTab.explorer.tab,
    WorkspaceTab.filter.tab,
    WorkspaceTab.analysis.tab,
    WorkspaceTab.review.tab,
    WorkspaceTab.solitaire.tab,
    const PaneTab(WorkspaceTab.book, 'My books'),
  ],
  open: const [WorkspaceTab.moves],
);

/// The card's tabs in the Repertoire trainer: Train first and always
/// there, the moves beside it to read a line in, and the explorer to be
/// shown when wanted.
PaneTabs<WorkspaceTab> trainerTabs() => PaneTabs(
  const [
    PaneTab(WorkspaceTab.train, 'Train', pinned: true),
    PaneTab(WorkspaceTab.moves, 'Moves'),
    PaneTab(WorkspaceTab.explorer, 'Explorer'),
  ],
  open: const [WorkspaceTab.moves],
);

/// The card's tabs in Tactics: the puzzle first and always there, the game
/// it came from beside it, and the explorer to be shown when wanted. The
/// repertoire's tabs mean nothing here and are not offered.
PaneTabs<WorkspaceTab> puzzleTabs() => PaneTabs(
  const [
    PaneTab(WorkspaceTab.puzzle, 'Puzzle', pinned: true),
    PaneTab(WorkspaceTab.source, 'Game'),
    PaneTab(WorkspaceTab.moves, 'Moves'),
    PaneTab(WorkspaceTab.explorer, 'Explorer'),
  ],
  open: const [WorkspaceTab.source],
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
/// closed is shown or closed by name, wherever among the panes it is open,
/// and the keys that walk them are written beside the entries that take
/// them. Without a [layout] — the analysis board's single strip — the tabs
/// are [tabs]' own.
List<AppAction> tabActions(
  PaneTabs<WorkspaceTab> tabs, {
  ActionLayout? layout,
}) => [
  for (final tab in tabs.tabs)
    if (!tab.pinned)
      (layout?.isOpen(tab.id) ?? tabs.isOpen(tab.id))
          ? AppAction(
              'Close ${tab.title}',
              layout == null
                  ? () => tabs.close(tab.id)
                  : switch (layout.paneOf(tab.id)) {
                      final pane? when layout.canClose(pane, tab.id) =>
                        () => layout.closeTab(pane, tab.id),
                      _ => null,
                    },
              shortcut: tabs.selected == tab.id ? AppKey.closeTab.label : null,
              group: 'Action Tabs',
              alternatives: layout?.destinations(tab.id) ?? const [],
            )
          : AppAction(
              'Show ${tab.title}',
              layout == null
                  ? () => tabs.show(tab.id)
                  : () => layout.reveal(tab.id),
              group: 'Action Tabs',
              alternatives: layout?.destinations(tab.id) ?? const [],
            ),
  AppAction(
    'Next tab',
    tabs.open.length < 2 ? null : tabs.next,
    shortcut: AppKey.nextTab.label,
    group: 'Action Tabs',
  ),
];
