import 'package:chess_auto_prep/utils/app_shortcuts.dart';
import 'package:chess_auto_prep/utils/keyboard_shortcut_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dead bindings', () {
    // The bug class this catches: a binding that can never fire, while a
    // tooltip somewhere keeps advertising its key. It used to be invisible
    // until a user pressed the key and nothing happened.
    KeyBinding shadow({bool preempts = false, bool repeats = false}) =>
        KeyBinding.run(
          LogicalKeyboardKey.keyR,
          'Reveal current move',
          () {},
          preempts: preempts,
          repeats: repeats,
        );

    KeyBinding shadowed({bool repeats = false}) => KeyBinding.run(
      LogicalKeyboardKey.keyR,
      'Return to mainline',
      () {},
      repeats: repeats,
    );

    test('an unreachable binding throws, naming both sides', () {
      expect(
        () => runKeyBindings([shadow(), shadowed()], LogicalKeyboardKey.keyR),
        throwsA(
          isA<FlutterError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Return to mainline'),
              contains('Reveal current move'),
              contains('preempts: true'),
            ),
          ),
        ),
      );
    });

    test('preempts: true is how deliberate shadowing is spelled', () {
      expect(
        runKeyBindings([
          shadow(preempts: true),
          shadowed(),
        ], LogicalKeyboardKey.keyR),
        KeyEventResult.handled,
      );
    });

    test('a binding that can decline never shadows a later one', () {
      var fallbackRan = false;
      final result = runKeyBindings([
        KeyBinding(LogicalKeyboardKey.keyR, 'Declines', () => false),
        KeyBinding.run(
          LogicalKeyboardKey.keyR,
          'Runs',
          () => fallbackRan = true,
        ),
      ], LogicalKeyboardKey.keyR);
      expect(result, KeyEventResult.handled);
      expect(fallbackRan, isTrue);
    });

    test('arrow navigation and modified letter shortcuts coexist', () {
      // Queue navigation uses an arrow while Ctrl+S and Shift+S toggle
      // solitaire; all can be registered on the same screen.
      expect(
        () => runKeyBindings([
          ...KeyBinding.forShortcut(AppShortcut.nextItem, 'Next game', () {}),
          ...KeyBinding.forShortcut(
            AppShortcut.solitaire,
            'Toggle solitaire',
            () {},
          ),
        ], LogicalKeyboardKey.keyS),
        returnsNormally,
      );
    });

    test('a repeat-ignoring binding leaves repeats to a later one', () {
      expect(
        () => runKeyBindings([
          shadow(),
          shadowed(repeats: true),
        ], LogicalKeyboardKey.keyR),
        returnsNormally,
      );
    });
  });

  group('isTextInputFocused', () {
    testWidgets('returns false when no focus', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Hello'))),
      );
      expect(isTextInputFocused(), isFalse);
    });

    testWidgets('returns true when TextField has focus', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TextField(autofocus: true))),
      );
      await tester.pump();
      expect(isTextInputFocused(), isTrue);
    });
  });

  group('handleKeyBindings while a text field has focus', () {
    /// A screen-shaped fixture: a Focus dispatching [bindings] above a
    /// TextField, the way every screen wraps its content.
    Future<void> pumpScreen(
      WidgetTester tester,
      List<KeyBinding> bindings,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(
              onKeyEvent: (node, event) =>
                  handleKeyBindings(bindings, event, node: node),
              child: const TextField(autofocus: true),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('Escape blurs the field instead of firing bindings', (
      tester,
    ) async {
      var escapeFired = false;
      await pumpScreen(tester, [
        KeyBinding.run(
          LogicalKeyboardKey.escape,
          'Leave',
          () => escapeFired = true,
        ),
      ]);
      expect(isTextInputFocused(), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(isTextInputFocused(), isFalse, reason: 'first Escape blurs');
      expect(escapeFired, isFalse, reason: 'the binding is not the blur');

      // With the field blurred, the next Escape reaches the screen's ladder.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(escapeFired, isTrue);
    });

    testWidgets('other keys still never fire while typing', (tester) async {
      var fired = false;
      await pumpScreen(tester, [
        KeyBinding.run(
          LogicalKeyboardKey.arrowDown,
          'Next',
          () => fired = true,
        ),
      ]);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(fired, isFalse);
      expect(isTextInputFocused(), isTrue);
    });
  });
}
