import 'package:chess_auto_prep/ui/app_icons.dart';
import 'package:chess_auto_prep/ui/row_actions.dart';
import 'package:chess_auto_prep/ui/theme.dart';
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
}
