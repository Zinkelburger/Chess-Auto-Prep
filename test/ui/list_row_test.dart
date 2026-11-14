// One row of a list, its column's header and the dialog that picks one of
// many: the fills, where the words sit, and how the menu opens.
import 'package:chess_auto_prep/ui/choice_dialog.dart';
import 'package:chess_auto_prep/ui/list_row.dart';
import 'package:chess_auto_prep/ui/pane_header.dart';
import 'package:chess_auto_prep/ui/row_actions.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _show(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: darkTheme(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 300, child: child),
      ),
    ),
  ),
);

void main() {
  group('a list row', () {
    Color? fill(WidgetTester tester) => tester
        .widget<Material>(
          find.descendant(
            of: find.byType(ListRow),
            matching: find.byType(Material),
          ),
        )
        .color;

    testWidgets('is clear unless it is the one open or picked', (tester) async {
      await _show(tester, const ListRow(child: Text('Najdorf')));
      expect(fill(tester), Colors.transparent);
      await _show(tester, const ListRow(picked: true, child: Text('Najdorf')));
      expect(fill(tester), selectedTint);
      await _show(
        tester,
        const ListRow(selected: true, picked: true, child: Text('Najdorf')),
      );
      final scheme = Theme.of(tester.element(find.text('Najdorf'))).colorScheme;
      expect(fill(tester), scheme.secondaryContainer);
    });

    testWidgets('its words start a step in, and end one before the edge or '
        'a small one before the menu', (tester) async {
      await _show(tester, const ListRow(child: SizedBox.expand()));
      final row = tester.getRect(find.byType(ListRow));
      final words = tester.getRect(find.byType(SizedBox).last);
      expect(words.left - row.left, Space.m);
      expect(row.right - words.right, Space.m);
      await _show(
        tester,
        ListRow(
          menu: [rowAction('Rename…', () {})],
          child: const SizedBox.expand(),
        ),
      );
      expect(
        row.right - tester.getRect(find.byType(RowActions)).right,
        Space.xs,
      );
    });

    testWidgets('a right click opens its menu where the pointer is', (
      tester,
    ) async {
      await _show(
        tester,
        ListRow(
          menu: [rowAction('Rename…', () {})],
          child: const Text('Najdorf'),
        ),
      );
      final at = tester.getCenter(find.text('Najdorf'));
      await tester.tapAt(at, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Rename…'), findsOneWidget);
      expect(
        (tester.getTopLeft(find.text('Rename…')) - at).distance,
        lessThan(60),
      );
    });

    testWidgets('a right click on a row without a menu opens nothing', (
      tester,
    ) async {
      await _show(tester, const ListRow(child: Text('Najdorf')));
      await tester.tapAt(
        tester.getCenter(find.text('Najdorf')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
    });

    testWidgets('Shift+F10 on the row opens its menu', (tester) async {
      await _show(
        tester,
        ListRow(
          onTap: () {},
          menu: [rowAction('Rename…', () {})],
          child: const Text('Najdorf'),
        ),
      );
      Focus.of(tester.element(find.text('Najdorf'))).requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('Rename…'), findsOneWidget);
    });
  });

  group('a column header', () {
    testWidgets('its name starts a step in, or right after the way back', (
      tester,
    ) async {
      await _show(tester, const PaneHeader('Repertoires'));
      final header = tester.getRect(find.byType(PaneHeader));
      expect(
        tester.getTopLeft(find.text('Repertoires')).dx,
        header.left + Space.m,
      );
      await _show(
        tester,
        const PaneHeader(
          'Chapters',
          leading: SizedBox(key: ValueKey('back'), width: 20, height: 20),
        ),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('back'))).dx,
        header.left,
      );
      expect(
        tester.getTopLeft(find.text('Chapters')).dx,
        tester.getTopRight(find.byKey(const ValueKey('back'))).dx,
      );
    });

    testWidgets('its controls follow the name after a small gap, and it '
        'sits a step under the top with nothing under it', (tester) async {
      await _show(
        tester,
        const PaneHeader(
          'Repertoires',
          actions: [SizedBox(key: ValueKey('add'), width: 20, height: 30)],
        ),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('add'))).dx,
        tester.getTopRight(find.text('Repertoires')).dx + Space.xs,
      );
      expect(tester.getSize(find.byType(PaneHeader)).height, Space.s + 30);
    });

    testWidgets('a count ends a step from the edge, or a small one from its '
        'control', (tester) async {
      await _show(tester, const CountLine('12 of 340'));
      final line = tester.getRect(find.byType(CountLine));
      expect(
        line.right - tester.getRect(find.text('12 of 340')).right,
        Space.m,
      );
      await _show(
        tester,
        const CountLine(
          '12 of 340',
          action: SizedBox(key: ValueKey('filter'), width: 20, height: 20),
        ),
      );
      expect(
        line.right -
            tester.getTopRight(find.byKey(const ValueKey('filter'))).dx,
        Space.xs,
      );
    });
  });

  group('the choice dialog', () {
    late List<String?> answers;

    Future<void> ask(WidgetTester tester, List<String> options) async {
      answers = [];
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => answers.add(
                await showChoiceDialog<String>(
                  context,
                  title: 'Add to repertoire',
                  options: options,
                  label: (option) => option,
                  hint: 'Search repertoires',
                  empty: 'No repertoires yet.',
                ),
              ),
              child: const Text('Ask'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
    }

    const options = ["King's Indian", 'Najdorf', 'Nimzo-Indian'];

    testWidgets('opens with every option and the caret in its search', (
      tester,
    ) async {
      await ask(tester, options);
      for (final option in options) {
        expect(find.text(option), findsOneWidget);
      }
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);
    });

    testWidgets('typing filters, and Enter takes the one thing left', (
      tester,
    ) async {
      await ask(tester, options);
      await tester.enterText(find.byType(TextField), 'indian');
      await tester.pump();
      expect(find.text('Najdorf'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(answers, isEmpty, reason: 'two are left');
      await tester.enterText(find.byType(TextField), 'NIMZO');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(answers, ['Nimzo-Indian']);
    });

    testWidgets('says why the list is empty: nothing at all, or nothing that '
        'matches', (tester) async {
      await ask(tester, const []);
      expect(find.text('No repertoires yet.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(answers, [null]);
      await ask(tester, options);
      await tester.enterText(find.byType(TextField), 'grob');
      await tester.pump();
      final message = find.text('Nothing matches "grob".');
      expect(message, findsOneWidget);
      expect(
        tester.getTopLeft(message).dx,
        tester.getTopLeft(find.byType(TextField)).dx,
      );
    });
  });
}
