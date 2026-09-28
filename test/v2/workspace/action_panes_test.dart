import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/action_layout.dart';
import 'package:chess_auto_prep/v2/workspace/action_panes.dart';
import 'package:chess_auto_prep/v2/workspace/workspace_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_explorer.dart';
import '../support/session_fixture.dart';

void main() {
  testWidgets(
    'presets place panes, Actions target a slot, and hidden tabs survive',
    (tester) async {
      final fixture = await openSession('[Result "*"]\n\n1. e4 *');
      final settings = SettingsStore();
      final explorer = explorerOver(fixture.session, settings: settings);
      final layout = ActionLayout(newWorkspaceTabs(), explorer);
      addTearDown(() {
        layout.dispose();
        explorer.dispose();
        settings.dispose();
        fixture.dispose();
      });
      await tester.binding.setSurfaceSize(const Size(900, 680));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(
            body: ActionPanes(
              layout: layout,
              body: (_, index, tab) => Text('Body $index ${tab.title}'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Body 0 Expectimax'), findsOneWidget);
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      final a = tester.getRect(find.byKey(const ValueKey('action-pane-0')));
      final b = tester.getRect(find.byKey(const ValueKey('action-pane-1')));
      expect(a.top, b.top);
      expect(a.right, lessThanOrEqualTo(b.left));
      await tester.tap(find.byTooltip('3 panes: left and two on the right'));
      await tester.pumpAndSettle();
      final rightTop = tester.getRect(
        find.byKey(const ValueKey('action-pane-1')),
      );
      final rightBottom = tester.getRect(
        find.byKey(const ValueKey('action-pane-2')),
      );
      expect(rightTop.left, rightBottom.left);
      expect(rightTop.bottom, lessThanOrEqualTo(rightBottom.top));
      await tester.tap(find.byTooltip('4 panes: quadrants'));
      await tester.pumpAndSettle();
      for (var index = 0; index < 4; index++) {
        layout.actions
            .firstWhere(
              (action) => action.label == 'Pane ${index + 1}: Explorer',
            )
            .run!();
      }
      await tester.pumpAndSettle();
      expect(
        find.textContaining(RegExp(r'Body \d Explorer')),
        findsNWidgets(4),
      );
      final topLeft = tester.getRect(
        find.byKey(const ValueKey('action-pane-0')),
      );
      final bottomLeft = tester.getRect(
        find.byKey(const ValueKey('action-pane-2')),
      );
      expect(topLeft.left, bottomLeft.left);
      expect(topLeft.bottom, lessThanOrEqualTo(bottomLeft.top));
      await tester.tap(find.byTooltip('1 pane'));
      await tester.pumpAndSettle();
      expect(layout.active, 0);
      expect(find.textContaining(RegExp(r'Body \d Explorer')), findsOneWidget);
      await tester.tap(find.byTooltip('4 panes: quadrants'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(RegExp(r'Body \d Explorer')),
        findsNWidgets(4),
      );
      await tester.tap(find.text('Body 2 Explorer'));
      expect(layout.active, 2);
      layout.tabs.show(WorkspaceTab.moves);
      await tester.pumpAndSettle();
      expect(find.text('Body 2 Moves'), findsOneWidget);
      expect(layout.pane(0).selected, WorkspaceTab.explorer);
      layout.pane(2).show(WorkspaceTab.train);
      layout.select(0);
      expect(layout.isOpen(WorkspaceTab.train), isTrue);
      layout.arrange(1);
      expect(layout.isOpen(WorkspaceTab.train), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
