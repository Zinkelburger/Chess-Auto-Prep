import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/app_overflow_menu.dart';

Widget _wrap(List<AppMenuEntry> entries) => MaterialApp(
  home: Scaffold(
    appBar: AppBar(actions: [AppOverflowMenu(entries: entries)]),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders nothing at all when it has no entries', (tester) async {
    await tester.pumpWidget(_wrap(const []));

    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets('runs the entry that was tapped, not its neighbour', (
    tester,
  ) async {
    final ran = <String>[];
    await tester.pumpWidget(
      _wrap([
        AppMenuEntry(label: 'First', onRun: () => ran.add('First')),
        AppMenuEntry(label: 'Second', onRun: () => ran.add('Second')),
        AppMenuEntry(label: 'Third', onRun: () => ran.add('Third')),
      ]),
    );

    await _open(tester);
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();

    expect(ran, ['Second']);
  });

  testWidgets('a divider above a row does not shift which row runs', (
    tester,
  ) async {
    // The entry list and the popup's item list differ in length once
    // dividers are in play; the row must still carry its own index.
    final ran = <String>[];
    await tester.pumpWidget(
      _wrap([
        AppMenuEntry(label: 'Action', onRun: () => ran.add('Action')),
        AppMenuEntry(
          label: 'Settings',
          dividerAbove: true,
          onRun: () => ran.add('Settings'),
        ),
      ]),
    );

    await _open(tester);
    expect(find.byType(PopupMenuDivider), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(ran, ['Settings']);
  });

  testWidgets('a leading divider is dropped rather than drawn on nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap([AppMenuEntry(label: 'Only', dividerAbove: true, onRun: () {})]),
    );

    await _open(tester);

    expect(find.byType(PopupMenuDivider), findsNothing);
  });

  testWidgets('a disabled entry cannot be run', (tester) async {
    var ran = false;
    await tester.pumpWidget(
      _wrap([
        AppMenuEntry(label: 'Nope', enabled: false, onRun: () => ran = true),
      ]),
    );

    await _open(tester);
    await tester.tap(find.text('Nope'));
    await tester.pumpAndSettle();

    expect(ran, isFalse);
  });

  testWidgets('checked entries show a tick and unchecked ones do not', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap([
        AppMenuEntry(label: 'On', checked: true, onRun: () {}),
        AppMenuEntry(label: 'Off', checked: false, onRun: () {}),
      ]),
    );

    await _open(tester);

    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('a hint is a hoverable ⓘ, never a sentence in the row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap([
        AppMenuEntry(
          label: 'Find tricks…',
          onRun: () {},
          hint: 'Plays the other side and hunts poisonous moves.',
        ),
      ]),
    );

    await _open(tester);

    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(
      find.text('Plays the other side and hunts poisonous moves.'),
      findsNothing,
    );
  });

  testWidgets('a shortcut is shown beside its label', (tester) async {
    await tester.pumpWidget(
      _wrap([
        AppMenuEntry(label: 'Edit in Study', shortcut: 'A', onRun: () {}),
      ]),
    );

    await _open(tester);

    expect(find.text('A'), findsOneWidget);
  });
}
