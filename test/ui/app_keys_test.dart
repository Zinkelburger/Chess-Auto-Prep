import 'package:chess_auto_prep/ui/app_keys.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keys are named the way a tooltip writes them', () {
    expect(AppKey.save.label, 'Ctrl+S');
    expect(AppKey.previousTab.label, 'Ctrl+Shift+Tab');
    expect(AppKey.settings.label, 'Ctrl+,');
    expect(AppKey.back.label, '←');
    expect(AppKey.historyBack.label, 'Alt+←');
    expect(AppKey.leave.label, 'Esc');
    expect(AppKey.flip.tip('Flip board'), 'Flip board (F)');
  });

  test('the Shortcuts list names every key but not the macOS twins', () {
    expect(AppKey.start.allLabels, 'Home / PgUp');
    expect(AppKey.save.allLabels, 'Ctrl+S');
    expect(AppKey.enterVariation.allLabels, 'Enter');
    expect(AppKey.rate.allLabels, '1–4');
  });

  test('no key does two things in one place', () {
    for (final place in KeyPlace.values) {
      final seen = <String, AppKey>{};
      for (final key in AppKey.values.where((k) => k.place == place)) {
        for (final activator in key.keys) {
          final name = keyName(activator);
          expect(
            seen[name] ?? key,
            key,
            reason: '$name is both ${seen[name]} and $key in ${place.label}',
          );
          seen[name] = key;
        }
      }
    }
  });

  test('every action has its own name, so a Shortcuts row is findable', () {
    final names = AppKey.values.map((k) => k.action).toList();
    expect(names.toSet().length, names.length);
  });

  test('a key accepts its own press and no other', () {
    const down = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyF,
      logicalKey: LogicalKeyboardKey.keyF,
      timeStamp: Duration.zero,
    );
    expect(AppKey.flip.accepts(down), isTrue);
    expect(AppKey.undo.accepts(down), isFalse);
  });

  test('every key is bound with exactly its modifiers', () {
    String bound(AppKey key) => [
      for (final activator in key.keys.cast<SingleActivator>())
        keyName(activator) + (activator.includeRepeats ? '' : ' once'),
    ].join(' / ');
    expect(
      {for (final key in AppKey.values) key.name: bound(key)},
      {
        'moveActions': 'Shift+F10 / Context Menu',
        'settings': 'Ctrl+, / Cmd+,',
        'openFile': 'Ctrl+O / Cmd+O',
        'paste': 'Ctrl+V / Cmd+V',
        'analysisBoard': 'Ctrl+N / Cmd+N',
        'fullScreen': 'F11',
        'historyBack': 'Alt+←',
        'historyForward': 'Alt+→',
        'play': 'Space',
        'nextGame': '↓',
        'previousGame': '↑',
        'closeDialog': 'Esc',
        'squareLeft': '←',
        'squareRight': '→',
        'squareUp': '↑',
        'squareDown': '↓',
        'squareChoose': 'Enter / Space',
        'squareClear': 'Esc',
        'focusMenu': 'Shift+F10 / Context Menu',
        'back': '←',
        'forward': '→',
        'start': 'Home / PgUp',
        'end': 'End / PgDn',
        'enterVariation': 'Enter / Enter',
        'leave': 'Esc once',
        'flip': 'F',
        'undo': 'Ctrl+Z / Cmd+Z',
        'save': 'Ctrl+S / Cmd+S',
        'nextTab': 'Ctrl+Tab',
        'previousTab': 'Ctrl+Shift+Tab',
        'closeTab': 'Ctrl+W / Cmd+W',
        'commitComment': 'Ctrl+Enter / Cmd+Enter',
        'clearMove': 'Esc',
        'nextStep': 'Space',
        'skipLine': '↓',
        'leaveLesson': 'Esc',
        'rate': '1 / 2 / 3 / 4',
        'stepBack': '←',
        'stepForward': '→',
        'firstMove': 'Home / PgUp',
        'lastMove': 'End / PgDn',
        'flipBoards': 'F',
        'closePreview': 'Esc',
      },
    );
  });
}
