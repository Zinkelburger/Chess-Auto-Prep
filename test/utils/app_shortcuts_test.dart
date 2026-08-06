import 'package:chess_auto_prep/utils/app_shortcuts.dart';
import 'package:chess_auto_prep/utils/keyboard_shortcut_utils.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // runKeyBindings reads HardwareKeyboard.instance for the modifier state.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('registry invariants', () {
    test('every entry has at least one chord', () {
      // The const constructor cannot assert this itself, so it is asserted
      // here instead.
      for (final shortcut in AppShortcut.all) {
        expect(shortcut.chords, isNotEmpty);
      }
    });

    test('no entry lists the same chord twice', () {
      for (final shortcut in AppShortcut.all) {
        expect(
          shortcut.chords.toSet(),
          hasLength(shortcut.chords.length),
          reason: 'duplicate chord in "${shortcut.label}"',
        );
      }
    });

    test('everyScreen entries are move-text safe on every chord', () {
      // This is the invariant that forces previous/next to be P/S. If
      // someone "improves" nextItem to N, this fails: the tactics panel's
      // always-hot move box would type "N" instead of stepping the queue.
      for (final shortcut in AppShortcut.all) {
        if (shortcut.scope != ShortcutScope.everyScreen) continue;
        for (final chord in shortcut.chords) {
          final binding = KeyBinding(
            chord.key,
            'probe',
            () => true,
            control: chord.control,
            shift: chord.shift,
          );
          expect(
            binding.safeWhileTypingMoves,
            isTrue,
            reason:
                '${chord.label} can appear in typed move text, so '
                '"${shortcut.label}" cannot work on a screen with an '
                'always-hot move box',
          );
        }
      }
    });

    test('previous/next are the documented pair', () {
      // A change here is a deliberate app-wide decision, not a refactor.
      expect(AppShortcut.previousItem.label, 'P or ↑');
      expect(AppShortcut.nextItem.label, 'S or ↓');
    });
  });

  group('labels', () {
    test('render the glyphs tooltips have always shown', () {
      expect(AppShortcut.backOneMove.label, '←');
      expect(AppShortcut.goToStart.label, 'Home');
      expect(AppShortcut.leave.label, 'Esc');
      expect(AppShortcut.autoPlay.label, 'Space');
      expect(AppShortcut.searchGames.label, '/');
      expect(AppShortcut.flipBoard.label, 'F');
    });

    test('join multiple chords with "or"', () {
      expect(AppShortcut.fullScreen.label, 'Ctrl+F or F11');
      expect(AppShortcut.solitaire.label, 'Ctrl+S or Shift+S');
    });

    test('modifiers render in front of the key', () {
      expect(AppShortcut.undo.label, 'Ctrl+Z');
      expect(AppShortcut.previousTrapInLine.label, 'Shift+←');
      expect(AppShortcut.nextTrapInLine.label, 'Shift+→');
    });
  });

  group('KeyBinding.forShortcut', () {
    test('binds every chord the label advertises', () {
      final bindings = KeyBinding.forShortcut(
        AppShortcut.previousItem,
        'Previous game',
        () {},
      );
      expect(
        bindings.map((b) => b.chord),
        AppShortcut.previousItem.chords,
        reason: 'a screen must bind all of what its tooltip promises',
      );
      expect(bindings.every((b) => b.alwaysConsumes), isTrue);
    });

    test('carries modifiers through to each binding', () {
      final bindings = KeyBinding.forShortcut(
        AppShortcut.solitaire,
        'Toggle solitaire',
        () {},
      );
      expect(bindings, hasLength(2));
      expect(bindings[0].control, isTrue);
      expect(bindings[0].shift, isFalse);
      expect(bindings[1].control, isFalse);
      expect(bindings[1].shift, isTrue);
    });

    test('forShortcutIf keeps the action able to decline', () {
      var asked = 0;
      final bindings = KeyBinding.forShortcutIf(
        AppShortcut.nextItem,
        'Next finding',
        () {
          asked++;
          return false;
        },
      );
      expect(bindings.every((b) => b.alwaysConsumes), isFalse);

      final result = runKeyBindings(bindings, LogicalKeyboardKey.keyS);
      expect(result, KeyEventResult.ignored);
      expect(asked, 1, reason: 'declining lets a later binding have the key');
    });
  });
}
