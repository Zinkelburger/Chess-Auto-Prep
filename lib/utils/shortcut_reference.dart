import 'app_shortcuts.dart';

/// Discoverable descriptions; key labels always come from the live registry.
/// Context is explicit because a bare key can serve different views.
class ShortcutReference {
  const ShortcutReference(this.group, this.description, this.shortcut);
  final String group;
  final String description;
  final AppShortcut shortcut;
}

const shortcutReference = [
  ShortcutReference(
    'Navigation',
    'Previous game, chapter, puzzle or finding',
    AppShortcut.previousItem,
  ),
  ShortcutReference(
    'Navigation',
    'Next game, chapter, puzzle or finding',
    AppShortcut.nextItem,
  ),
  ShortcutReference(
    'Navigation',
    'Previous move; at a variation start, return to its parent',
    AppShortcut.backOneMove,
  ),
  ShortcutReference('Navigation', 'Next move', AppShortcut.forwardOneMove),
  ShortcutReference('Navigation', 'Start of line', AppShortcut.goToStart),
  ShortcutReference('Navigation', 'End of line', AppShortcut.goToEnd),
  ShortcutReference(
    'Navigation',
    'Return to mainline (game reader and analysis)',
    AppShortcut.returnToMainline,
  ),
  ShortcutReference(
    'Navigation',
    'Close dialog or leave the current mode or panel',
    AppShortcut.leave,
  ),
  ShortcutReference('Navigation', 'Next panel tab', AppShortcut.nextTab),
  ShortcutReference(
    'Game reader',
    'Focus the current variation',
    AppShortcut.focusVariation,
  ),
  ShortcutReference(
    'Game reader',
    'Return to reading position, then parent variation',
    AppShortcut.returnToParentLine,
  ),
  ShortcutReference('Game reader', 'Search games', AppShortcut.searchGames),
  ShortcutReference(
    'Game reader',
    'Go to game number',
    AppShortcut.goToGameNumber,
  ),
  ShortcutReference('Game reader', 'Play or pause moves', AppShortcut.autoPlay),
  ShortcutReference(
    'Game reader',
    'Continue playback to the next game',
    AppShortcut.autoNextGame,
  ),
  ShortcutReference('Game reader', 'Edit in Study', AppShortcut.amendGame),
  ShortcutReference('Game reader', 'Paste PGN', AppShortcut.pastePgn),
  ShortcutReference(
    'Game reader',
    'Show collection opening tree',
    AppShortcut.toggleOpeningTree,
  ),
  ShortcutReference(
    'Solitaire',
    'Enter or leave solitaire',
    AppShortcut.solitaire,
  ),
  ShortcutReference(
    'Solitaire',
    'Start from the setup strip',
    AppShortcut.startSolitaire,
  ),
  ShortcutReference('Solitaire', 'Reveal current move', AppShortcut.revealMove),
  ShortcutReference(
    'Solitaire',
    'Hint: highlight the piece that moves',
    AppShortcut.hintMove,
  ),
  ShortcutReference('Board and analysis', 'Flip board', AppShortcut.flipBoard),
  ShortcutReference(
    'Board and analysis',
    'Toggle live engine',
    AppShortcut.toggleEngine,
  ),
  ShortcutReference(
    'Board and analysis',
    'Toggle fullscreen (game reader)',
    AppShortcut.fullScreen,
  ),
  ShortcutReference(
    'Repertoire and study',
    'Toggle Expectimax',
    AppShortcut.toggleExpectimax,
  ),
  ShortcutReference(
    'Repertoire and study',
    'Toggle lines panel',
    AppShortcut.toggleLinesPanel,
  ),
  ShortcutReference(
    'Repertoire and study',
    'Comment current move',
    AppShortcut.commentMove,
  ),
  ShortcutReference(
    'Repertoire and study',
    'Browse study in game reader',
    AppShortcut.browseInViewer,
  ),
  ShortcutReference('Repertoire and study', 'Undo', AppShortcut.undo),
  ShortcutReference(
    'Repertoire and study',
    'Paste FEN (also works in text fields)',
    AppShortcut.pasteFen,
  ),
  ShortcutReference(
    'Training',
    'Show solution or next learning step',
    AppShortcut.toggleSolution,
  ),
  ShortcutReference(
    'Training',
    'Analyze position',
    AppShortcut.analyzePosition,
  ),
  ShortcutReference(
    'Training',
    'Toggle automatic advance',
    AppShortcut.autoAdvance,
  ),
  ShortcutReference('Training', 'Restart line', AppShortcut.restartLine),
  ShortcutReference('Training', 'Focus move input', AppShortcut.focusMoveInput),
  ShortcutReference(
    'Traps and findings',
    'Toggle trap tour',
    AppShortcut.toggleTrapTour,
  ),
  ShortcutReference(
    'Traps and findings',
    'Dismiss current finding',
    AppShortcut.dismissFinding,
  ),
  ShortcutReference(
    'Traps and findings',
    'Previous trap in line',
    AppShortcut.previousTrapInLine,
  ),
  ShortcutReference(
    'Traps and findings',
    'Next trap in line',
    AppShortcut.nextTrapInLine,
  ),
];
