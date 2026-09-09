/// Central registry for app commands, their key chords and the Settings reference.
/// Unassigned actions keep their identity so handlers and tooltips both follow
/// the same policy: no chord means no binding and no shortcut hint.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One key plus the modifiers it requires. Bare chords (no [control], no
/// [shift]) fire only when *no* modifier is held, so `S` and `Ctrl+S` are
/// different chords and never collide.
@immutable
class KeyChord {
  const KeyChord(this.key, {this.control = false, this.shift = false});

  final LogicalKeyboardKey key;

  /// Requires Ctrl, or Cmd on macOS — the same "primary modifier" the
  /// dispatcher matches on.
  final bool control;

  final bool shift;

  /// How this chord is written in a tooltip: `P`, `↑`, `Ctrl+F`, `Shift+→`.
  String get label =>
      '${control ? _primaryModifierLabel : ''}'
      '${shift ? 'Shift+' : ''}'
      '${_keyLabel(key)}';

  @override
  bool operator ==(Object other) =>
      other is KeyChord &&
      other.key == key &&
      other.control == control &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(key, control, shift);

  @override
  String toString() => label;
}

String get _primaryModifierLabel =>
    defaultTargetPlatform == TargetPlatform.macOS ? 'Cmd+' : 'Ctrl+';

/// Display glyph for a key. Spelled out rather than derived from
/// [LogicalKeyboardKey.keyLabel] for the keys where that reads badly
/// ("Arrow Up", "Escape"), and because these glyphs are what the tooltips
/// have always shown.
String _keyLabel(LogicalKeyboardKey key) {
  final named = _namedGlyphs[key];
  if (named != null) return named;
  final label = key.keyLabel;
  return label.isNotEmpty ? label.toUpperCase() : (key.debugName ?? '?');
}

final Map<LogicalKeyboardKey, String> _namedGlyphs = {
  LogicalKeyboardKey.arrowUp: '↑',
  LogicalKeyboardKey.arrowDown: '↓',
  LogicalKeyboardKey.arrowLeft: '←',
  LogicalKeyboardKey.arrowRight: '→',
  LogicalKeyboardKey.escape: 'Esc',
  LogicalKeyboardKey.space: 'Space',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.pageUp: 'Page Up',
  LogicalKeyboardKey.pageDown: 'Page Down',
  LogicalKeyboardKey.backspace: 'Backspace',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.slash: '/',
  LogicalKeyboardKey.f11: 'F11',
};

/// A named action's keyboard shortcut: the chords that fire it, in the order
/// tooltips list them (the primary chord first).
@immutable
class AppShortcut {
  /// Entries spell out their chord list — `AppShortcut([KeyChord(…)])` — so
  /// every one of them is a compile-time constant. (A single-chord
  /// convenience constructor is not possible: Dart cannot build a list in a
  /// `const` initializer list.)
  const AppShortcut(this.chords, {this.scope = ShortcutScope.anyScreen});

  /// An action with no keyboard binding. Mouse/menu controls remain available.
  const AppShortcut.unassigned()
    : chords = const [],
      scope = ShortcutScope.anyScreen;

  bool get isAssigned => chords.isNotEmpty;

  /// The chords that fire this action; empty for unassigned actions.
  final List<KeyChord> chords;

  /// Where this entry is expected to work — checked by
  /// `app_shortcuts_test.dart`, which is what keeps a future editor from
  /// quietly moving [nextItem] onto the knight.
  final ShortcutScope scope;

  /// What every tooltip for this action shows: `↑`, `Ctrl+V`.
  String get label => chords.map((c) => c.label).join(' or ');

  // ── Stepping the current queue ─────────────────────────────────────────
  //
  // The one pair that means "previous / next thing in whatever list is in
  // front of me": game, chapter, chess-position finding, trap-tour stop,
  // tactics puzzle, training line. ←/→ can never take this job — they step
  // *moves* on every board screen — and the vertical arrows are move-text
  // safe, so they keep working even in the tactics panel's always-hot move box.

  static const previousItem = AppShortcut([
    KeyChord(LogicalKeyboardKey.arrowUp),
  ], scope: ShortcutScope.everyScreen);

  static const nextItem = AppShortcut([
    KeyChord(LogicalKeyboardKey.arrowDown),
  ], scope: ShortcutScope.everyScreen);

  // ── Moving through a game ──────────────────────────────────────────────

  static const backOneMove = AppShortcut([
    KeyChord(LogicalKeyboardKey.arrowLeft),
  ]);
  static const forwardOneMove = AppShortcut([
    KeyChord(LogicalKeyboardKey.arrowRight),
  ]);
  static const goToStart = AppShortcut([KeyChord(LogicalKeyboardKey.home)]);
  static const goToEnd = AppShortcut([KeyChord(LogicalKeyboardKey.end)]);
  static const returnToMainline = AppShortcut.unassigned();

  static const focusVariation = AppShortcut([
    KeyChord(LogicalKeyboardKey.enter),
  ]);
  static const returnToParentLine = AppShortcut([
    KeyChord(LogicalKeyboardKey.escape),
  ]);

  // ── Board and panels ───────────────────────────────────────────────────

  static const flipBoard = AppShortcut([KeyChord(LogicalKeyboardKey.keyF)]);
  static const toggleEngine = AppShortcut.unassigned();
  static const toggleExpectimax = AppShortcut.unassigned();
  static const toggleLinesPanel = AppShortcut.unassigned();
  static const nextTab = AppShortcut.unassigned();

  static const fullScreen = AppShortcut([KeyChord(LogicalKeyboardKey.f11)]);

  /// Leave whatever you are in, innermost first — the app-wide Escape
  /// contract. Every screen spells out its own ladder in the description.
  static const leave = AppShortcut([KeyChord(LogicalKeyboardKey.escape)]);

  // ── PGN viewer ─────────────────────────────────────────────────────────

  static const autoPlay = AppShortcut([KeyChord(LogicalKeyboardKey.space)]);
  static const autoNextGame = AppShortcut.unassigned();
  static const amendGame = AppShortcut.unassigned();
  static const goToGameNumber = AppShortcut.unassigned();

  static const searchGames = AppShortcut.unassigned();

  static const revealMove = AppShortcut.unassigned();

  /// Solitaire only: highlight the piece that moves.
  static const hintMove = AppShortcut.unassigned();
  static const pastePgn = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyV, control: true),
  ]);

  // ── Study and annotation ───────────────────────────────────────────────

  static const commentMove = AppShortcut.unassigned();
  static const browseInViewer = AppShortcut.unassigned();
  static const undo = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyZ, control: true),
  ]);

  // ── Trainers ───────────────────────────────────────────────────────────

  static const toggleSolution = AppShortcut([
    KeyChord(LogicalKeyboardKey.space),
  ]);
  static const analyzePosition = AppShortcut.unassigned();
  static const autoAdvance = AppShortcut.unassigned();
  static const restartLine = AppShortcut.unassigned();
  static const focusMoveInput = AppShortcut.unassigned();

  // ── Traps and findings ─────────────────────────────────────────────────

  static const toggleTrapTour = AppShortcut.unassigned();
  static const dismissFinding = AppShortcut.unassigned();

  static const previousTrapInLine = AppShortcut.unassigned();
  static const nextTrapInLine = AppShortcut.unassigned();

  static const startSolitaire = AppShortcut([
    KeyChord(LogicalKeyboardKey.enter),
  ]);
  static const pasteFen = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyV, control: true, shift: true),
  ]);

  /// Every assigned action; checked against the reference below.
  static const all = <AppShortcut>[
    previousItem,
    nextItem,
    backOneMove,
    forwardOneMove,
    goToStart,
    goToEnd,
    focusVariation,
    startSolitaire,
    pasteFen,
    returnToParentLine,
    flipBoard,
    fullScreen,
    leave,
    autoPlay,
    pastePgn,
    undo,
    toggleSolution,
  ];
}

/// Where an entry is expected to work. See [AppShortcut.scope].
enum ShortcutScope {
  /// Bound on the screens that want it; may be a move-text key, in which case
  /// it simply does not fire while a move is being typed.
  anyScreen,

  /// Must work on *every* screen, including one with an always-hot move box,
  /// so every chord has to be move-text safe.
  everyScreen,
}

/// A row in Settings. Labels are derived from the actual binding.
class ShortcutReference {
  const ShortcutReference(this.group, this.description, this.shortcut);
  final String group;
  final String description;
  final AppShortcut shortcut;
}

const shortcutReference = [
  ShortcutReference(
    'Lists',
    'Previous game, chapter, puzzle or finding',
    AppShortcut.previousItem,
  ),
  ShortcutReference(
    'Lists',
    'Next game, chapter, puzzle or finding',
    AppShortcut.nextItem,
  ),
  ShortcutReference('Boards', 'Previous move', AppShortcut.backOneMove),
  ShortcutReference('Boards', 'Next move', AppShortcut.forwardOneMove),
  ShortcutReference('Boards', 'Start of line', AppShortcut.goToStart),
  ShortcutReference('Boards', 'End of line', AppShortcut.goToEnd),
  ShortcutReference('Boards', 'Flip board', AppShortcut.flipBoard),
  ShortcutReference(
    'App',
    'Close dialog, leave panel or exit mode',
    AppShortcut.leave,
  ),
  ShortcutReference(
    'Game reader',
    'Focus variation',
    AppShortcut.focusVariation,
  ),
  ShortcutReference(
    'Game reader',
    'Return to parent variation',
    AppShortcut.returnToParentLine,
  ),
  ShortcutReference('Game reader', 'Play / pause moves', AppShortcut.autoPlay),
  ShortcutReference('Game reader', 'Fullscreen', AppShortcut.fullScreen),
  ShortcutReference('Game reader', 'Paste PGN', AppShortcut.pastePgn),
  ShortcutReference('Solitaire setup', 'Start', AppShortcut.startSolitaire),
  ShortcutReference(
    'Training',
    'Show solution / next learning step',
    AppShortcut.toggleSolution,
  ),
  ShortcutReference('Study / repertoire', 'Undo', AppShortcut.undo),
  ShortcutReference('Study / repertoire', 'Paste FEN', AppShortcut.pasteFen),
];
