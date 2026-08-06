/// The app's keyboard shortcut registry: one named entry per action, holding
/// **every** chord that fires it and the **one** label its tooltips show.
///
/// Why this exists: a shortcut used to be two independent strings — a
/// [KeyBinding] in the screen and a hand-typed `shortcut: '↑'` in the widget
/// — with nothing tying them together. They drifted (a doc comment still
/// promised "N/P" long after those bindings became ↓/↑), and a binding that
/// could never fire was invisible until someone pressed the key and nothing
/// happened. Here the chords *are* the label, so the two cannot disagree:
///
/// ```dart
/// // screen: binds P and ↑, both of them
/// ...KeyBinding.forShortcut(AppShortcut.previousItem, 'Previous game', prev),
/// // widget: renders "Previous game (P or ↑)" — never hand-typed
/// ShortcutTooltip.of(AppShortcut.previousItem, description: 'Previous game', …)
/// ```
///
/// **Uniqueness is per screen, not global.** Two screens may reuse a chord for
/// different actions ([searchGames] and [focusMoveInput] are both `/`); what
/// must never happen is one screen binding a chord twice, which
/// `handleKeyBindings` asserts against in debug builds.
///
/// **Move-text safety.** On screens with an always-hot move box (the tactics
/// panel), a bare key that can appear in SAN or UCI is typed into the box and
/// never reaches the shortcut. [KeyBinding.safeWhileTypingMoves] decides that.
/// Entries meant to work on *every* screen — [previousItem], [nextItem] —
/// therefore avoid the files a–h, the pieces K/Q/R/N/B, castling O, capture x,
/// ranks 1–8 and `-`/`=`. That constraint is why previous/next are P and S:
/// N would be the knight and could never fire while a move is being typed.
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

  /// The chords that fire this action. Never empty — `app_shortcuts_test.dart`
  /// checks that, since a `const` constructor cannot assert on list length.
  final List<KeyChord> chords;

  /// Where this entry is expected to work — checked by
  /// `app_shortcuts_test.dart`, which is what keeps a future editor from
  /// quietly moving [nextItem] onto the knight.
  final ShortcutScope scope;

  /// What every tooltip for this action shows: `P or ↑`, `Ctrl+F or F11`.
  String get label => chords.map((c) => c.label).join(' or ');

  // ── Stepping the current queue ─────────────────────────────────────────
  //
  // The one pair that means "previous / next thing in whatever list is in
  // front of me": game, chapter, chess-position finding, trap-tour stop,
  // tactics puzzle, training line. ←/→ can never take this job — they step
  // *moves* on every board screen — and both chords here are move-text safe,
  // so they keep working even in the tactics panel's always-hot move box.

  static const previousItem = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyP),
    KeyChord(LogicalKeyboardKey.arrowUp),
  ], scope: ShortcutScope.everyScreen);

  static const nextItem = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyS),
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
  static const returnToMainline = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyR),
  ]);

  // ── Board and panels ───────────────────────────────────────────────────

  static const flipBoard = AppShortcut([KeyChord(LogicalKeyboardKey.keyF)]);
  static const toggleEngine = AppShortcut([KeyChord(LogicalKeyboardKey.keyE)]);
  static const toggleExpectimax = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyX),
  ]);
  static const toggleLinesPanel = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyL),
  ]);
  static const toggleOpeningTree = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyT),
  ]);
  static const nextTab = AppShortcut([KeyChord(LogicalKeyboardKey.tab)]);

  static const fullScreen = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyF, control: true),
    KeyChord(LogicalKeyboardKey.f11),
  ]);

  /// Leave whatever you are in, innermost first — the app-wide Escape
  /// contract. Every screen spells out its own ladder in the description.
  static const leave = AppShortcut([KeyChord(LogicalKeyboardKey.escape)]);

  // ── PGN viewer ─────────────────────────────────────────────────────────

  static const autoPlay = AppShortcut([KeyChord(LogicalKeyboardKey.space)]);
  static const autoNextGame = AppShortcut([KeyChord(LogicalKeyboardKey.keyW)]);
  static const amendGame = AppShortcut([KeyChord(LogicalKeyboardKey.keyA)]);
  static const goToGameNumber = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyG),
  ]);

  /// `/` — the search key everywhere it is free, and unambiguous here because
  /// the viewer has no move box to focus. (It moved off `S` when previous/next
  /// claimed that key; `S` is the queue, on every screen, and one meaning per
  /// key is worth more than the mnemonic.)
  static const searchGames = AppShortcut([KeyChord(LogicalKeyboardKey.slash)]);

  static const solitaire = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyS, control: true),
    KeyChord(LogicalKeyboardKey.keyS, shift: true),
  ]);

  static const revealMove = AppShortcut([KeyChord(LogicalKeyboardKey.keyR)]);
  static const pastePgn = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyV, control: true),
  ]);

  // ── Study and annotation ───────────────────────────────────────────────

  static const commentMove = AppShortcut([KeyChord(LogicalKeyboardKey.keyC)]);
  static const browseInViewer = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyA),
  ]);
  static const undo = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyZ, control: true),
  ]);

  // ── Trainers ───────────────────────────────────────────────────────────

  static const toggleSolution = AppShortcut([
    KeyChord(LogicalKeyboardKey.space),
  ]);
  static const analyzePosition = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyV),
  ]);
  static const autoAdvance = AppShortcut([KeyChord(LogicalKeyboardKey.keyJ)]);
  static const restartLine = AppShortcut([KeyChord(LogicalKeyboardKey.keyR)]);
  static const focusMoveInput = AppShortcut([
    KeyChord(LogicalKeyboardKey.slash),
  ]);

  // ── Traps and findings ─────────────────────────────────────────────────

  static const toggleTrapTour = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyT),
  ]);
  static const dismissFinding = AppShortcut([
    KeyChord(LogicalKeyboardKey.keyD),
  ]);

  /// Shift+←/→ jump between traps *inside the current line* — a different axis
  /// from [previousItem]/[nextItem], which step the trap list itself.
  static const previousTrapInLine = AppShortcut([
    KeyChord(LogicalKeyboardKey.arrowLeft, shift: true),
  ]);
  static const nextTrapInLine = AppShortcut([
    KeyChord(LogicalKeyboardKey.arrowRight, shift: true),
  ]);

  /// Every entry above, for the invariant tests.
  static const all = <AppShortcut>[
    previousItem,
    nextItem,
    backOneMove,
    forwardOneMove,
    goToStart,
    goToEnd,
    returnToMainline,
    flipBoard,
    toggleEngine,
    toggleExpectimax,
    toggleLinesPanel,
    toggleOpeningTree,
    nextTab,
    fullScreen,
    leave,
    autoPlay,
    autoNextGame,
    amendGame,
    goToGameNumber,
    searchGames,
    solitaire,
    revealMove,
    pastePgn,
    commentMove,
    browseInViewer,
    undo,
    toggleSolution,
    analyzePosition,
    autoAdvance,
    restartLine,
    focusMoveInput,
    toggleTrapTour,
    dismissFinding,
    previousTrapInLine,
    nextTrapInLine,
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
