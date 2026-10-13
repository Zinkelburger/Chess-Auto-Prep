import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_action.dart';

/// Where a key does what it says.
enum KeyPlace {
  window('Window'),
  board('Board and moves'),
  squares('Chessboard square focus'),
  tabs('Focused tabs'),
  comment('Comment box'),
  moveBox('Move box'),
  trainer('Repertoire trainer'),
  bughouse('Bughouse lab');

  const KeyPlace(this.label);

  final String label;
}

/// Every key the app answers to, in one list: the handlers bind these keys,
/// the tooltips name them and Settings ▸ Shortcuts lists them, so the three
/// cannot disagree. A new key is a value here, bound where it is handled
/// with [bind] or [accepts].
///
/// Ctrl bindings carry a Cmd twin for macOS; the first key of each is the
/// one a tooltip names.
enum AppKey {
  moveActions('Actions for the focused move', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.f10, shift: true),
    SingleActivator(LogicalKeyboardKey.contextMenu),
  ]),
  // The window: the shell binds these over every mode.
  settings('Settings', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.comma, control: true),
    SingleActivator(LogicalKeyboardKey.comma, meta: true),
  ]),
  actions('Actions', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.keyK, control: true),
    SingleActivator(LogicalKeyboardKey.keyK, meta: true),
  ]),
  toggleList('Show or hide the list', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.keyB, control: true),
    SingleActivator(LogicalKeyboardKey.keyB, meta: true),
  ]),
  positions('Positions', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.keyP, control: true),
    SingleActivator(LogicalKeyboardKey.keyP, meta: true),
  ]),
  openFile('Open a PGN file', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.keyO, control: true),
    SingleActivator(LogicalKeyboardKey.keyO, meta: true),
  ]),
  paste('Paste PGN or FEN', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.keyV, control: true),
    SingleActivator(LogicalKeyboardKey.keyV, meta: true),
  ]),
  pastePosition('Paste the position only', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true),
    SingleActivator(LogicalKeyboardKey.keyV, meta: true, shift: true),
  ]),
  analysisBoard('New analysis board', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.keyN, control: true),
    SingleActivator(LogicalKeyboardKey.keyN, meta: true),
  ]),
  search('Search from the board', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.keyG, control: true),
    SingleActivator(LogicalKeyboardKey.keyG, meta: true),
  ]),
  fullScreen('Full screen', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.f11),
  ]),
  historyBack('Back to the last place', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true),
  ]),
  historyForward('Forward again', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.arrowRight, alt: true),
  ]),
  play('Play the game; show the puzzle solution', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.space),
  ]),
  nextGame('Next game or puzzle', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.arrowDown),
  ]),
  previousGame('Previous game or puzzle', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.arrowUp),
  ]),

  /// Bound by Flutter's dialog route rather than [bind]: every dialog
  /// closes on it. Listed so its close button and Shortcuts name it.
  closeDialog('Close the dialog', KeyPlace.window, [
    SingleActivator(LogicalKeyboardKey.escape),
  ]),

  squareLeft('Explore left', KeyPlace.squares, [
    SingleActivator(LogicalKeyboardKey.arrowLeft),
  ]),
  squareRight('Explore right', KeyPlace.squares, [
    SingleActivator(LogicalKeyboardKey.arrowRight),
  ]),
  squareUp('Explore up', KeyPlace.squares, [
    SingleActivator(LogicalKeyboardKey.arrowUp),
  ]),
  squareDown('Explore down', KeyPlace.squares, [
    SingleActivator(LogicalKeyboardKey.arrowDown),
  ]),
  squareChoose('Select piece or destination', KeyPlace.squares, [
    SingleActivator(LogicalKeyboardKey.enter),
    SingleActivator(LogicalKeyboardKey.space),
  ]),
  squareClear('Clear selected piece', KeyPlace.squares, [
    SingleActivator(LogicalKeyboardKey.escape),
  ]),
  tabMenu('Open tab menu', KeyPlace.tabs, [
    SingleActivator(LogicalKeyboardKey.f10, shift: true),
    SingleActivator(LogicalKeyboardKey.contextMenu),
  ]),

  // The workspace: the board, the moves and the card beside them.
  back('Back one move', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.arrowLeft),
  ]),
  forward('Forward one move', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.arrowRight),
  ]),
  start('To the start', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.home),
    SingleActivator(LogicalKeyboardKey.pageUp),
  ]),
  end('To the end', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.end),
    SingleActivator(LogicalKeyboardKey.pageDown),
  ]),
  enterVariation('Into the variation at the cursor', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.enter),
    SingleActivator(LogicalKeyboardKey.numpadEnter),
  ]),
  leave('Out of the variation, edit strip or sitting', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false),
  ]),
  flip('Flip board', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.keyF),
  ]),
  engine('Engine on or off', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.keyE),
  ]),
  edit('Edit notes and moves', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.keyE, control: true),
    SingleActivator(LogicalKeyboardKey.keyE, meta: true),
  ]),
  undo('Undo', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.keyZ, control: true),
    SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
  ]),
  save('Save changes', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.keyS, control: true),
    SingleActivator(LogicalKeyboardKey.keyS, meta: true),
  ]),
  nextTab('Next tab', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.tab, control: true),
  ]),
  previousTab('Previous tab', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true),
  ]),
  closeTab('Close tab', KeyPlace.board, [
    SingleActivator(LogicalKeyboardKey.keyW, control: true),
    SingleActivator(LogicalKeyboardKey.keyW, meta: true),
  ]),
  // A character, not a key: `/` is Shift+7 on some keyboards.
  typeMove('Type a move', KeyPlace.board, [CharacterActivator('/')]),

  commitComment('Finish the comment', KeyPlace.comment, [
    SingleActivator(LogicalKeyboardKey.enter, control: true),
    SingleActivator(LogicalKeyboardKey.enter, meta: true),
  ]),
  clearMove('Clear the typed move', KeyPlace.moveBox, [
    SingleActivator(LogicalKeyboardKey.escape),
  ]),

  nextStep('Next', KeyPlace.trainer, [
    SingleActivator(LogicalKeyboardKey.space),
  ]),
  skipLine('Skip this line', KeyPlace.trainer, [
    SingleActivator(LogicalKeyboardKey.arrowDown),
  ]),
  leaveLesson('Back to lines', KeyPlace.trainer, [
    SingleActivator(LogicalKeyboardKey.escape),
  ]),

  /// Again, Hard, Good, Easy, in that order.
  rate('Rate the review', KeyPlace.trainer, [
    SingleActivator(LogicalKeyboardKey.digit1),
    SingleActivator(LogicalKeyboardKey.digit2),
    SingleActivator(LogicalKeyboardKey.digit3),
    SingleActivator(LogicalKeyboardKey.digit4),
  ], named: '1–4'),

  stepBack('Step back', KeyPlace.bughouse, [
    SingleActivator(LogicalKeyboardKey.arrowLeft),
  ]),
  stepForward('Step forward', KeyPlace.bughouse, [
    SingleActivator(LogicalKeyboardKey.arrowRight),
  ]),
  firstMove('To the first move', KeyPlace.bughouse, [
    SingleActivator(LogicalKeyboardKey.home),
  ]),
  lastMove('To the last move', KeyPlace.bughouse, [
    SingleActivator(LogicalKeyboardKey.end),
  ]),
  closePreview('Close the preview', KeyPlace.bughouse, [
    SingleActivator(LogicalKeyboardKey.escape),
  ]),
  bughouseEngine('Toggle engine', KeyPlace.bughouse, [
    SingleActivator(LogicalKeyboardKey.keyE),
  ]);

  const AppKey(this.action, this.place, this.keys, {String? named})
    : _named = named;

  /// What the key does, as the Shortcuts list says it.
  final String action;
  final KeyPlace place;
  final List<ShortcutActivator> keys;
  final String? _named;

  /// The key in the words a tooltip uses: `Ctrl+E`, `F`, `←`.
  String get label => _named ?? keyName(keys.first);

  /// Every key that does it, without the macOS twins: `Home / PgUp`.
  String get allLabels =>
      _named ??
      {
        for (final key in keys)
          if (key is! SingleActivator || !key.meta) keyName(key),
      }.join(' / ');

  /// [description] with this key after it: `Flip board (F)`.
  String tip(String description) => withKey(description, label);

  /// Each of the keys, doing [run].
  Map<ShortcutActivator, T> bind<T>(T run) => {
    for (final key in keys) key: run,
  };

  /// Whether [event] is one of the keys.
  bool accepts(KeyEvent event) =>
      keys.any((key) => key.accepts(event, HardwareKeyboard.instance));
}

/// [key] as a person writes it: modifiers first, then the key.
String keyName(ShortcutActivator key) => switch (key) {
  SingleActivator() => [
    if (key.control) 'Ctrl',
    if (key.meta) 'Cmd',
    if (key.alt) 'Alt',
    if (key.shift) 'Shift',
    _keyNames[key.trigger] ?? key.trigger.keyLabel,
  ].join('+'),
  CharacterActivator(:final character) => character,
  _ => '$key',
};

final _keyNames = {
  LogicalKeyboardKey.arrowLeft: '←',
  LogicalKeyboardKey.arrowRight: '→',
  LogicalKeyboardKey.arrowUp: '↑',
  LogicalKeyboardKey.arrowDown: '↓',
  LogicalKeyboardKey.escape: 'Esc',
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.numpadEnter: 'Enter',
  LogicalKeyboardKey.space: 'Space',
  LogicalKeyboardKey.pageUp: 'PgUp',
  LogicalKeyboardKey.pageDown: 'PgDn',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.comma: ',',
};
