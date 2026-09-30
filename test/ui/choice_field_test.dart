import 'package:chess_auto_prep/ui/choice_field.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final changed = <String>[];
  final submitted = <String>[];

  Future<void> pump(WidgetTester tester, {required bool submitOnly}) async {
    changed.clear();
    submitted.clear();
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: ChoiceField(
              text: '',
              options: const ['Carlsen', 'Caruana', 'Giri'],
              hint: 'Player',
              onChanged: submitOnly ? null : changed.add,
              onSubmitted: submitOnly ? submitted.add : null,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a box that takes every keystroke still gets each one, and a '
      'click on a suggestion', (tester) async {
    await pump(tester, submitOnly: false);
    await tester.enterText(find.byType(TextField), 'Car');
    await tester.pump();
    expect(changed, ['Car']);
    await tester.tap(find.text('Caruana'));
    await tester.pump();
    expect(changed, ['Car', 'Caruana']);
  });

  testWidgets('a box that acts on submit hears only a pick or Enter', (
    tester,
  ) async {
    await pump(tester, submitOnly: true);
    await tester.enterText(find.byType(TextField), 'Car');
    await tester.pump();
    expect(submitted, isEmpty);
    await tester.tap(find.text('Carlsen'));
    await tester.pump();
    expect(submitted, ['Carlsen']);

    await tester.enterText(find.byType(TextField), ' Nobody known ');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, ['Carlsen', 'Nobody known']);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, ['Carlsen', 'Nobody known', '']);
  });
}
