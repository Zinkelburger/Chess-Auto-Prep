import 'package:chess_auto_prep/v2/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/v2/features/settings/settings_dialog.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SettingsStore store;
  String? token = 'abc';
  var opened = 0;

  setUp(() {
    store = SettingsStore();
    token = 'abc';
    opened = 0;
  });

  tearDown(() => store.dispose());

  List<SettingGroup> rows() => settingGroups(
    store: store,
    coresAvailable: 8,
    loadLichessToken: () async => token,
    saveLichessToken: (value) async {
      token = value;
      return true;
    },
    openLogFolder: () => opened++,
  );

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SettingsDialog(store: store, groups: rows),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('opens on Look, with one place per group and no more', (
    tester,
  ) async {
    await pump(tester);
    for (final place in [
      'Look',
      'Engine',
      'Repertoire',
      'Files',
      'Accounts',
      'App',
    ]) {
      expect(find.text(place), findsOneWidget);
    }
    expect(find.text('Board coordinates'), findsOneWidget);
    expect(find.text('CPU cores'), findsNothing);
  });

  testWidgets('a place shows its rows; a number is stepped and typed', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Engine'));
    await tester.pumpAndSettle();
    expect(find.text('CPU cores'), findsOneWidget);
    expect(find.text('of 8 on this computer'), findsOneWidget);
    final plus = find.widgetWithIcon(IconButton, Icons.add).first;
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(store.value.engineCores, 2);
    final boxes = find.byType(TextField);
    // The first box after the search field is the cores box.
    await tester.enterText(boxes.at(1), '99');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(store.value.engineCores, 8, reason: 'kept inside the range');
  });

  testWidgets('a choice and a switch write at once', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();
    expect(store.value.boardCoordinates, isFalse);
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(store.value.copyFilesIntoDocuments, isFalse);
  });

  testWidgets('typing finds rows across the places', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, 'mem');
    await tester.pumpAndSettle();
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('ENGINE'), findsOneWidget);
    expect(find.text('Board coordinates'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches "zzz".'), findsOneWidget);
  });

  testWidgets('the token is loaded, saved on leaving the field, and '
      'emptying it signs out', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    final field = find.byType(TextField).at(1);
    expect(tester.widget<TextField>(field).controller?.text, 'abc');
    await tester.enterText(field, 'newtoken');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(token, 'newtoken');
    expect(find.text('Saved'), findsOneWidget);
    await tester.enterText(field, '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(token, '');
    expect(find.text('Signed out'), findsOneWidget);
  });

  testWidgets('the log folder opens from App', (tester) async {
    await pump(tester);
    await tester.tap(find.text('App'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    expect(opened, 1);
  });

  testWidgets('a store in trouble says so under the rows', (tester) async {
    await pump(tester);
    expect(find.textContaining('could not'), findsNothing);
  });
}
