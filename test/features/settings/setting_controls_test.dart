// The secret row: a token typed in is hidden, written once whether Enter or
// leaving the field sends it, and answered with a word.
import 'dart:async';

import 'package:chess_auto_prep/features/settings/setting_controls.dart';
import 'package:chess_auto_prep/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> written;
  late bool keeps;

  setUp(() {
    written = [];
    keeps = true;
  });

  SettingRow secret({Future<String?> Function()? load}) => SettingRow(
    'Token',
    SecretSetting(
      load: load ?? () async => null,
      save: (value) async {
        written.add(value);
        return keeps;
      },
    ),
  );

  Future<void> pump(WidgetTester tester, SettingRow row) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Column(
            children: [
              SettingRowView(row: row),
              const TextField(key: ValueKey('elsewhere')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder field() => find.descendant(
    of: find.byType(SettingRowView),
    matching: find.byType(TextField),
  );

  testWidgets('what is typed is hidden', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, secret());
    await tester.enterText(field(), 'lip_mine');
    await tester.pump();
    expect(
      tester.getSemantics(find.byType(EditableText).first),
      containsSemantics(isTextField: true, isObscured: true),
    );
    semantics.dispose();
  });

  testWidgets('leaving the field writes what was typed', (tester) async {
    await pump(tester, secret());
    await tester.enterText(field(), 'lip_mine');
    await tester.tap(find.byKey(const ValueKey('elsewhere')));
    await tester.pumpAndSettle();
    expect(written, ['lip_mine']);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('Enter and then leaving the field write once', (tester) async {
    final answer = Completer<bool>();
    final row = SettingRow(
      'Token',
      SecretSetting(
        load: () async => null,
        save: (value) {
          written.add(value);
          return answer.future;
        },
      ),
    );
    await pump(tester, row);
    await tester.enterText(field(), 'lip_mine');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    // Left while the first write is still out.
    await tester.tap(find.byKey(const ValueKey('elsewhere')));
    await tester.pump();
    answer.complete(true);
    await tester.pumpAndSettle();
    // Kept now, so the same value is not written again.
    await tester.tap(field());
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(written, ['lip_mine']);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a kept token cleared says signed out', (tester) async {
    await pump(tester, secret(load: () async => 'lip_old'));
    await tester.enterText(field(), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(written, ['']);
    expect(find.text('Signed out'), findsOneWidget);
  });

  testWidgets('a value refused says not saved, and stays to be retried', (
    tester,
  ) async {
    keeps = false;
    await pump(tester, secret());
    await tester.enterText(field(), 'bad');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Not saved'), findsOneWidget);
    keeps = true;
    await tester.tap(field());
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(written, ['bad', 'bad']);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a row taken down before its value loads is left alone', (
    tester,
  ) async {
    final loading = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingRowView(row: secret(load: () => loading.future)),
        ),
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    loading.complete('lip_late');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
