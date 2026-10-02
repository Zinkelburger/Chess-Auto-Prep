import 'package:chess_auto_prep/ui/navigation_pages.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'both navigation tabs fit at 130% and remain keyboard reachable',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
              child: const SizedBox(
                key: ValueKey('navigation-rail'),
                width: 260,
                child: NavigationPages(
                  trailing: SizedBox(width: 34),
                  list: Text('List content'),
                  outline: Text('Chapter content'),
                ),
              ),
            ),
          ),
        ),
      );
      final rail = tester.getRect(
        find.byKey(const ValueKey('navigation-rail')),
      );
      for (final label in ['Repertoires', 'Chapters']) {
        final tab = find.widgetWithText(TextButton, label);
        final bounds = tester.getRect(tab);
        expect(bounds.left, greaterThanOrEqualTo(rail.left));
        expect(bounds.right, lessThanOrEqualTo(rail.right - 34));
        expect(tab.hitTestable(), findsOneWidget);
        await tester.tap(tab);
        await tester.pumpAndSettle();
        expect(
          find.text(label == 'Chapters' ? 'Chapter content' : 'List content'),
          findsOneWidget,
        );
      }
      final listButton = find.widgetWithText(TextButton, 'Repertoires');
      Focus.of(
        tester.element(
          find.descendant(of: listButton, matching: find.byType(Text)),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('List content'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching navigation preserves search and excludes hidden focus',
    (tester) async {
      final listFocus = FocusNode();
      final outlineFocus = FocusNode();
      addTearDown(listFocus.dispose);
      addTearDown(outlineFocus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 260,
              child: NavigationPages(
                trailing: const SizedBox.shrink(),
                list: TextField(
                  key: const ValueKey('list-search'),
                  focusNode: listFocus,
                ),
                outline: TextField(
                  key: const ValueKey('chapter-search'),
                  focusNode: outlineFocus,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('chapter-search')), findsOneWidget);
      expect(listFocus.canRequestFocus, isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('chapter-search')),
        'Sicilian',
      );
      await tester.tap(find.text('Repertoires'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('list-search')), findsOneWidget);
      expect(outlineFocus.canRequestFocus, isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('list-search')),
        'White',
      );
      await tester.tap(find.text('Chapters'));
      await tester.pumpAndSettle();
      expect(find.text('Sicilian'), findsOneWidget);
      await tester.tap(find.text('Repertoires'));
      await tester.pumpAndSettle();
      expect(find.text('White'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('parent can reset navigation and rename the retained list tab', (
    tester,
  ) async {
    var selected = 1;
    var label = 'Repertoires';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SizedBox(
                width: 260,
                child: NavigationPages(
                  selected: selected,
                  onSelected: (next) => setState(() => selected = next),
                  listLabel: label,
                  trailing: const SizedBox.shrink(),
                  list: const Text('List content'),
                  outline: const Text('Chapter content'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Repertoires'));
    await tester.pumpAndSettle();
    expect(selected, 0);
    expect(find.text('List content'), findsOneWidget);
    update(() {
      selected = 1;
      label = 'Positions';
    });
    await tester.pumpAndSettle();
    expect(find.text('Positions'), findsOneWidget);
    expect(find.text('Chapter content'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
