import 'package:chess_auto_prep/widgets/shortcut_tooltip.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppShortcuts', () {
    test('autoAdvanceToggle is documented single key', () {
      expect(AppShortcuts.autoAdvanceToggle, 'J');
    });
  });

  group('actionTooltip', () {
    test('appends shortcut in parentheses', () {
      expect(
        actionTooltip('Flip board', shortcut: 'F'),
        'Flip board (F)',
      );
      expect(
        actionTooltip('Undo last add', shortcut: 'Ctrl+Z'),
        'Undo last add (Ctrl+Z)',
      );
    });

    test('actionTooltipIf omits suffix when shortcut absent', () {
      expect(actionTooltipIf('Settings'), 'Settings');
      expect(actionTooltipIf('Reload', shortcut: ''), 'Reload');
      expect(actionTooltipIf('Next', shortcut: 'Space'), 'Next (Space)');
    });
  });

  group('ShortcutIconButton', () {
    testWidgets('tooltip includes shortcut on hover', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ShortcutIconButton(
              description: 'Next game',
              shortcut: 'N',
              onPressed: () {},
              icon: const Icon(Icons.skip_next),
            ),
          ),
        ),
      );

      final iconButton = tester.widget<IconButton>(find.byType(IconButton));
      expect(iconButton.tooltip, 'Next game (N)');
    });
  });

  group('shortcutTooltip', () {
    testWidgets('shows shortcut after hover delay', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: shortcutTooltip(
                description: 'Analyze',
                shortcut: 'A',
                child: ElevatedButton(
                  onPressed: () {},
                  child: const Text('Analyze'),
                ),
              ),
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.text('Analyze'));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: center);
      await gesture.moveTo(center);
      await tester.pump();
      expect(find.text('Analyze (A)'), findsNothing);

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.text('Analyze (A)'), findsOneWidget);
    });
  });

  group('ShortcutTooltip', () {
    testWidgets('asserts when shortcut is empty', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ShortcutTooltip(
              description: 'Action',
              shortcut: '',
              child: const Text('Go'),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isA<AssertionError>());
    });
  });
}
