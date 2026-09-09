import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/theme/app_motion.dart';
import 'package:chess_auto_prep/widgets/app_overflow_menu.dart';

Widget _wrap(
  List<AppMenuEntry> entries, {
  bool openOnHover = false,
  bool enabled = true,
}) => MaterialApp(
  home: Scaffold(
    appBar: AppBar(
      actions: [
        AppOverflowMenu(
          entries: entries,
          openOnHover: openOnHover,
          enabled: enabled,
        ),
      ],
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Actions'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'hover opens Actions and switches submenus without running actions',
    (tester) async {
      final ran = <String>[];
      await tester.pumpWidget(
        _wrap([
          AppMenuEntry(
            label: 'Tree',
            onRun: () {},
            children: [
              AppMenuEntry(
                label: 'Collection tree',
                onRun: () => ran.add('collection'),
              ),
              AppMenuEntry(
                label: 'Database explorer',
                onRun: () => ran.add('database'),
              ),
            ],
          ),
          AppMenuEntry(
            label: 'Export',
            onRun: () {},
            children: [
              AppMenuEntry(label: 'Export PGN', onRun: () => ran.add('export')),
            ],
          ),
        ], openOnHover: true),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 100));
      await mouse.moveTo(tester.getCenter(find.text('Actions')));
      await tester.pumpAndSettle();
      expect(find.text('Tree'), findsOneWidget);
      // A normal click after pointer entry must not undo the hover opening.
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      expect(find.text('Tree'), findsOneWidget);
      await mouse.moveTo(tester.getCenter(find.text('Tree')));
      await tester.pumpAndSettle();
      expect(find.text('Collection tree'), findsOneWidget);
      expect(find.text('Database explorer'), findsOneWidget);
      await mouse.moveTo(tester.getCenter(find.text('Export')));
      await tester.pumpAndSettle();
      expect(find.text('Collection tree'), findsNothing);
      expect(find.text('Export PGN'), findsOneWidget);
      expect(ran, isEmpty);
      await mouse.moveTo(tester.getCenter(find.text('Tree')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Database explorer'));
      await tester.pumpAndSettle();
      expect(ran, ['database']);
      expect(find.text('Tree'), findsNothing);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'hover menu supports Escape, outside click and disabled anchors',
    (tester) async {
      final entries = [
        AppMenuEntry(label: 'Paste PGN', shortcut: 'Ctrl+V', onRun: () {}),
      ];
      await tester.pumpWidget(_wrap(entries, openOnHover: true));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 100));
      await mouse.moveTo(tester.getCenter(find.text('Actions')));
      await tester.pumpAndSettle();
      expect(find.text('Paste PGN'), findsOneWidget);
      expect(find.text('Ctrl+V'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Paste PGN'), findsNothing);
      await mouse.moveTo(const Offset(10, 100));
      await mouse.moveTo(tester.getCenter(find.text('Actions')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 100));
      await tester.pumpAndSettle();
      expect(find.text('Paste PGN'), findsNothing);
      await tester.pumpWidget(
        _wrap(entries, openOnHover: true, enabled: false),
      );
      await mouse.moveTo(const Offset(10, 100));
      await mouse.moveTo(tester.getCenter(find.text('Actions')));
      await tester.pumpAndSettle();
      expect(find.text('Paste PGN'), findsNothing);
      await mouse.removePointer();
    },
  );

  testWidgets('export submenu opens on hover and runs only chosen action', (
    tester,
  ) async {
    final ran = <String>[];
    await tester.pumpWidget(
      _wrap([
        AppMenuEntry(
          label: 'Edit PGN',
          heading: 'Edit',
          onRun: () => ran.add('edit'),
        ),
        AppMenuEntry(
          label: 'Export',
          onRun: () {},
          children: [
            AppMenuEntry(label: 'Export as PGN', onRun: () => ran.add('pgn')),
            AppMenuEntry(label: 'Export as SCID', onRun: () => ran.add('scid')),
          ],
        ),
      ]),
    );
    await _open(tester);
    expect(find.text('Export as PGN'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.text('Export')));
    await tester.pumpAndSettle();
    expect(find.text('Export as PGN'), findsOneWidget);
    expect(ran, isEmpty);
    await tester.tap(find.text('Export as SCID'));
    await tester.pumpAndSettle();
    expect(ran, ['scid']);
    expect(find.text('Edit PGN'), findsNothing);
    await mouse.removePointer();
  });

  testWidgets('renders nothing at all when it has no entries', (tester) async {
    await tester.pumpWidget(_wrap(const []));

    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets('opens with the app-wide short menu animation', (tester) async {
    await tester.pumpWidget(_wrap([AppMenuEntry(label: 'Only', onRun: () {})]));

    expect(
      tester
          .widget<PopupMenuButton<int>>(find.byType(PopupMenuButton<int>))
          .popUpAnimationStyle,
      AppMotion.menuAnimation,
    );

    await tester.tap(find.text('Actions'));
    await tester.pump();
    await tester.pump(AppMotion.menu);
    expect(find.text('Only'), findsOneWidget);
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

  testWidgets('a group separator does not shift which row runs', (
    tester,
  ) async {
    // The entry list and the popup's item list differ in length once
    // separators are in play; the row must still carry its own index.
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

  testWidgets('a heading draws its section name and does not shift rows', (
    tester,
  ) async {
    final ran = <String>[];
    await tester.pumpWidget(
      _wrap([
        AppMenuEntry(
          label: 'Plan',
          heading: 'Add lines',
          onRun: () => ran.add('Plan'),
        ),
        AppMenuEntry(label: 'Generate', onRun: () => ran.add('Generate')),
        AppMenuEntry(
          label: 'Audit',
          heading: 'Check',
          onRun: () => ran.add('Audit'),
        ),
      ]),
    );

    await _open(tester);
    expect(find.text('ADD LINES'), findsOneWidget);
    expect(find.text('CHECK'), findsOneWidget);
    // A heading is not a row: tapping it selects nothing.
    await tester.tap(find.text('CHECK'), warnIfMissed: false);
    await tester.pump();
    expect(ran, isEmpty);

    await tester.tap(find.text('Audit'));
    await tester.pumpAndSettle();
    expect(ran, ['Audit']);
  });

  testWidgets('an anchor opens the same menu from a labelled control', (
    tester,
  ) async {
    var ran = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              AppOverflowMenu(
                anchor: const Text('Actions'),
                entries: [AppMenuEntry(label: 'Go', onRun: () => ran = true)],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.more_vert), findsNothing);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(ran, isTrue);
  });
}
