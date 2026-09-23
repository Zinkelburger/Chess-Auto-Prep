import 'package:chess_auto_prep/v2/ui/file_names.dart';
import 'package:chess_auto_prep/v2/ui/name_dialog.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the name dialog, types [typed] and presses its button; answers
/// what the dialog answered, null while it is still open.
Future<String?> _named(WidgetTester tester, String typed) async {
  String? answered;
  await tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => answered = await showNameDialog(
            context,
            title: 'New chapter',
            label: 'Chapter name',
            confirm: 'Create',
          ),
          child: const Text('Ask'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Ask'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), typed);
  await tester.tap(find.text('Create'));
  await tester.pumpAndSettle();
  return answered;
}

void main() {
  testWidgets('the dialog takes a name with a space at either end, and '
      'answers it without', (tester) async {
    expect(await _named(tester, 'Najdorf '), 'Najdorf');
    expect(await _named(tester, ' Najdorf'), 'Najdorf');
  });

  testWidgets('the dialog keeps a name it refuses, and says why', (
    tester,
  ) async {
    expect(await _named(tester, 'Main. '), isNull);
    expect(find.text('Names cannot end with a dot or space.'), findsOneWidget);
  });

  test('a plain name is fine', () {
    expect(nameProblem("King's Indian"), isNull);
    expect(nameProblem('Benoni  x'), isNull);
  });

  test('a name has to be something', () {
    expect(nameProblem('   '), 'Please enter a name.');
  });

  test('a name a filesystem cannot spell is refused', () {
    const message =
        r'Names cannot contain < > : " / \ | ? * or control characters.';
    expect(nameProblem('a/b'), message);
    expect(nameProblem('what?'), message);
    expect(nameProblem('line\nbreak'), message);
  });

  test('a trailing dot or space is refused, as Windows would', () {
    expect(nameProblem('Main '), 'Names cannot end with a dot or space.');
    expect(nameProblem('Main.'), 'Names cannot end with a dot or space.');
  });

  test('the names a directory listing already uses are refused', () {
    expect(nameProblem('.'), 'That name is reserved.');
    expect(nameProblem('..'), 'That name is reserved.');
  });

  test('a name that would hide the folder is refused', () {
    const message =
        'Names cannot start with a dot; the list would not show it.';
    expect(nameProblem('.Sicilian'), message);
    expect(nameProblem('  .hidden'), message);
    expect(nameProblem('e4.e5'), isNull, reason: 'a dot inside is fine');
  });

  test('the names Windows keeps for devices are refused', () {
    const message = 'That name is reserved by the operating system.';
    expect(nameProblem('CON'), message);
    expect(nameProblem('lpt1.pgn'), message);
  });

  test('a name longer than the cap is refused', () {
    expect(nameProblem('a' * 120), isNull);
    expect(nameProblem('a' * 121), 'Names must be 120 characters or fewer.');
  });
}
