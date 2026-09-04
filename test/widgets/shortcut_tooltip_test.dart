import 'package:chess_auto_prep/utils/app_shortcuts.dart';
import 'package:chess_auto_prep/widgets/shortcut_tooltip.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('actionTooltip', () {
    test('appends the registry label in parentheses', () {
      expect(
        actionTooltip('Flip board', shortcut: AppShortcut.flipBoard),
        'Flip board (F)',
      );
      expect(
        actionTooltip('Undo last add', shortcut: AppShortcut.undo),
        'Undo last add (Ctrl+Z)',
      );
    });

    test('a navigation action advertises its arrow key', () {
      expect(
        actionTooltip('Next game', shortcut: AppShortcut.nextItem),
        'Next game (↓)',
      );
    });

    test('actionTooltipIf omits the suffix when there is no shortcut', () {
      expect(actionTooltipIf('Settings'), 'Settings');
      expect(
        actionTooltipIf('Next', shortcut: AppShortcut.nextItem),
        'Next (↓)',
      );
    });
  });

  group('ShortcutIconButton', () {
    testWidgets('tooltip includes the shortcut on hover', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ShortcutIconButton(
              description: 'Next game',
              shortcut: AppShortcut.nextItem,
              onPressed: () {},
              icon: const Icon(Icons.skip_next),
            ),
          ),
        ),
      );

      final iconButton = tester.widget<IconButton>(find.byType(IconButton));
      expect(iconButton.tooltip, 'Next game (↓)');
    });
  });

  group('shortcutTooltip', () {
    testWidgets('shows the shortcut immediately on hover', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: shortcutTooltip(
                description: 'Analyze',
                shortcut: AppShortcut.analyzePosition,
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
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Analyze (V)'), findsOneWidget);
    });
  });

  group('ShortcutTooltip', () {
    testWidgets('renders the label the screens bind', (tester) async {
      // There is no "empty shortcut" case left to assert against: the API
      // takes an AppShortcut, and every registry entry has at least one
      // chord, so a tooltip advertising nothing is unrepresentable rather
      // than caught at runtime.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ShortcutTooltip(
              description: 'Previous game',
              shortcut: AppShortcut.previousItem,
              child: Text('Go'),
            ),
          ),
        ),
      );

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'Previous game (↑)');
    });
  });
}
