import 'package:chess_auto_prep/ui/app_action.dart';
import 'package:chess_auto_prep/ui/app_icons.dart';
import 'package:chess_auto_prep/ui/menu_entry.dart';
import 'package:chess_auto_prep/ui/row_actions.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A row's `⋯` menu: once one entry has a symbol, every label starts in the
/// same place; with none, no slot is held.
void main() {
  Future<void> openMenu(WidgetTester tester, List<Widget> entries) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Center(child: RowActions(children: entries)),
        ),
      ),
    );
    await tester.tap(find.byIcon(AppIcons.more));
    await tester.pumpAndSettle();
  }

  testWidgets('labels line up once any entry has a symbol', (tester) async {
    await openMenu(tester, [
      rowAction('Rename…', () {}, icon: AppIcons.edit),
      rowAction('Move to…', () {}),
      rowAction('Delete…', () {}, busy: true, icon: AppIcons.delete),
    ]);
    final rename = tester.getTopLeft(find.text('Rename…')).dx;
    expect(tester.getTopLeft(find.text('Move to…')).dx, rename);
    expect(tester.getTopLeft(find.text('Delete…')).dx, rename);
    // A busy entry is shown but off.
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, 'Delete…'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('a menu without symbols holds no slot', (tester) async {
    await openMenu(tester, [
      rowAction('Rename…', () {}),
      rowAction('Move to…', () {}),
    ]);
    final item = tester.getTopLeft(
      find.widgetWithText(MenuItemButton, 'Rename…'),
    );
    expect(
      tester.getTopLeft(find.text('Rename…')).dx - item.dx,
      lessThan(Space.l + IconSize.menu),
    );
  });

  double inset(WidgetTester tester, String label) =>
      tester.getTopLeft(find.text(label)).dx -
      tester.getTopLeft(find.widgetWithText(MenuItemButton, label)).dx;

  testWidgets('an entry is on unless busy', (tester) async {
    await openMenu(tester, [rowAction('Rename…', () {})]);
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, 'Rename…'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('an action without a symbol, alone, holds no slot', (
    tester,
  ) async {
    await openMenu(tester, [MenuEntry.action(AppAction('Rename…', () {}))]);
    expect(inset(tester, 'Rename…'), lessThan(Space.l + IconSize.menu));
  });

  testWidgets('a submenu with a symbol gives the other rows a slot', (
    tester,
  ) async {
    await openMenu(tester, [
      const SubmenuButton(
        leadingIcon: Icon(AppIcons.edit),
        menuChildren: [],
        child: Text('More'),
      ),
      rowAction('Plain', () {}),
    ]);
    expect(inset(tester, 'Plain'), greaterThanOrEqualTo(IconSize.menu));
  });

  testWidgets('a symbol is muted on a row that is on, and plain on one off', (
    tester,
  ) async {
    await openMenu(tester, [
      rowAction('On', () {}, icon: AppIcons.edit),
      rowAction('Off', null, icon: AppIcons.delete),
    ]);
    final scheme = darkTheme().colorScheme;
    expect(
      tester.widget<Icon>(find.byIcon(AppIcons.edit)).color,
      scheme.onSurfaceVariant,
    );
    expect(tester.widget<Icon>(find.byIcon(AppIcons.delete)).color, isNull);
  });

  testWidgets('a right click on an entry offers where else it opens', (
    tester,
  ) async {
    await openMenu(tester, [
      MenuEntry.action(
        AppAction(
          'Open',
          () {},
          alternatives: [AppAction('Open beside', () {})],
        ),
      ),
    ]);
    await tester.tap(find.text('Open'), buttons: kSecondaryButton);
    await tester.pump();
    expect(find.text('Open beside'), findsOneWidget);
  });
}
