import 'package:chess_auto_prep/utils/keyboard_shortcut_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isTextInputFocused', () {
    testWidgets('returns false when no focus', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Hello'))),
      );
      expect(isTextInputFocused(), isFalse);
    });

    testWidgets('returns true when TextField has focus', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TextField(autofocus: true))),
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
