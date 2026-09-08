import 'package:chess_auto_prep/core/slice_filter_controller.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/widgets/slice/header_filters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _show(
  WidgetTester tester,
  SliceFilterController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            child: HeaderFilters(
              controller: controller,
              games: const [
                (
                  headers: {'White': 'Carlsen, Magnus', 'Black': 'Alpha'},
                  pgnText: '*',
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _condition => find.widgetWithText(TextField, 'Choose condition');
Finder get _value => find.byType(TextField).last;

Future<void> _choose(WidgetTester tester, String query, String label) async {
  await tester.enterText(_condition.last, query);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('search a condition, edit its value, and retain numeric mode', (
    tester,
  ) async {
    final controller = SliceFilterController();
    addTearDown(controller.dispose);
    await _show(tester, controller);
    await _choose(tester, 'White rating at least', 'White rating at least');
    await tester.enterText(_value, '2200');
    await tester.pump();
    expect(controller.headerConfigs.single.toJson(), {
      'field': 'WhiteElo',
      'mode': 'after',
      'value': '2200',
    });
    // Bounds and text matching are all still searchable by their PGN field.
    await _choose(tester, 'Date before', 'In or before');
    await tester.enterText(_value, '1960');
    await tester.pump();
    expect(controller.headerConfigs.single.chipLabel, 'In or before 1960');
    expect(tester.takeException(), isNull);
  });

  testWidgets('exact ECO warnings and regex matching remain available', (
    tester,
  ) async {
    final controller = SliceFilterController();
    addTearDown(controller.dispose);
    await _show(tester, controller);
    await _choose(tester, 'ECO exact', 'ECO is');
    await tester.enterText(_value, 'B');
    await tester.pump();
    expect(find.text('Expected A00–E99'), findsOneWidget);
    await tester.enterText(_value, 'B90');
    await tester.pump();
    expect(find.text('Expected A00–E99'), findsNothing);
    await _choose(tester, 'Result regex', 'Result matches regex');
    await tester.enterText(_value, '^(1-0|0-1)\$');
    await tester.pump();
    expect(controller.headerConfigs.single.field, 'Result');
    expect(controller.headerConfigs.single.mode, MatchMode.regex);
    expect(controller.headerConfigs.single.value, '^(1-0|0-1)\$');
    expect(tester.takeException(), isNull);
  });

  testWidgets('add and remove conditions without losing other row values', (
    tester,
  ) async {
    final controller = SliceFilterController();
    addTearDown(controller.dispose);
    await _show(tester, controller);
    await tester.enterText(_value, '1960');
    // Focus moved to the value; let its previous choice popup close.
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filter'));
    await tester.pumpAndSettle();
    expect(_condition, findsNWidgets(2));
    expect(
      tester.widget<TextField>(_condition.last).focusNode!.hasFocus,
      isTrue,
    );
    await tester.enterText(_value, 'Carlsen; Magnus');
    await tester.pumpAndSettle();
    expect(find.textContaining('Carlsen, Magnus ×1'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove filter').first);
    await tester.pumpAndSettle();
    expect(controller.headerConfigs.single.field, kPlayerHeaderField);
    expect(controller.headerConfigs.single.value, 'Carlsen; Magnus');
    expect(find.text('Carlsen; Magnus'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Dispose the text fields before their controller, as the host does.
    await tester.pumpWidget(const SizedBox());
  });
}
