import 'package:chess_auto_prep/ui/choice_field.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final changed = <String>[];
  final submitted = <String>[];

  Future<void> pump(
    WidgetTester tester, {
    required bool submitOnly,
    List<String> options = const ['Carlsen', 'Caruana', 'Giri'],
    bool clear = true,
  }) async {
    if (clear) {
      changed.clear();
      submitted.clear();
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: ChoiceField(
              text: '',
              options: options,
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

  testWidgets('a cleared box that takes every keystroke is not given the '
      'first option on Enter', (tester) async {
    await pump(tester, submitOnly: false);
    await tester.enterText(find.byType(TextField), 'Car');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(changed, ['Car', '']);
  });

  testWidgets('a box whose options change offers the new ones when next '
      'focused, without anything typed', (tester) async {
    Future<void> focus() async {
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.pump();
    }

    Future<void> leave() async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
    }

    bool focused() =>
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus;

    await pump(tester, submitOnly: false);
    await focus();
    expect(find.text('Giri'), findsOneWidget);
    await leave();

    await pump(tester, submitOnly: false, options: ['Nakamura', 'So']);
    await focus();
    expect(find.text('Nakamura'), findsOneWidget);
    expect(find.text('Carlsen'), findsNothing);

    // Changed while the box is open: it keeps the focus, and what is typed
    // is matched against the new options.
    await pump(tester, submitOnly: false, options: ['Ding', 'Nakamura']);
    expect(focused(), isTrue);
    await tester.enterText(find.byType(TextField), 'D');
    await tester.pump();
    await tester.pump();
    expect(find.text('Ding'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await leave();
    await focus();
    expect(find.text('Ding'), findsOneWidget);
    expect(find.text('So'), findsNothing);
  });
}
