// The settings dialog's places: the chosen one is marked and none while a
// search is shown, each is a button to a screen reader, and a chosen place
// that goes away leaves the last one on screen.
import 'dart:ui' show SemanticsFlags, Tristate;

import 'package:chess_auto_prep/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/features/settings/settings_dialog.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/ui/search_field.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SettingsStore store;
  late ValueNotifier<int> also;
  late List<SettingGroup> groups;

  SettingGroup group(String name, String row) =>
      SettingGroup(name, [SettingRow(row, ActionSetting('Do', () {}))]);

  setUp(() {
    store = SettingsStore();
    also = ValueNotifier(0);
    groups = [
      group('Look', 'Board row'),
      group('Training', 'Lines row'),
      group('App', 'Log row'),
    ];
    addTearDown(store.dispose);
    addTearDown(also.dispose);
  });

  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SettingsDialog(store: store, groups: () => groups, also: also),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SemanticsFlags flags(WidgetTester tester, String name) =>
      tester.getSemantics(find.text(name)).flagsCollection;

  testWidgets('the chosen place is marked, and none while searching', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await show(tester);
    await tester.tap(find.text('Training'));
    await tester.pumpAndSettle();
    expect(flags(tester, 'Training').isSelected, Tristate.isTrue);
    expect(flags(tester, 'Look').isSelected, isNot(Tristate.isTrue));
    expect(flags(tester, 'Training').isButton, isTrue);
    await tester.enterText(
      find.descendant(
        of: find.byType(SearchField),
        matching: find.byType(TextField),
      ),
      'row',
    );
    await tester.pumpAndSettle();
    expect(flags(tester, 'Training').isSelected, isNot(Tristate.isTrue));
    semantics.dispose();
  });

  testWidgets('a chosen place that goes away leaves the last one shown', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('App'));
    await tester.pumpAndSettle();
    expect(find.text('Log row'), findsOneWidget);
    groups = groups.take(2).toList();
    also.value++;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Lines row'), findsOneWidget);
  });
}
