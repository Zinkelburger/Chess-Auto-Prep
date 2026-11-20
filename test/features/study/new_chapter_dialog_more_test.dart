// New chapter from the keyboard: the name is typed straight away and Enter
// creates; a refused name says why until the name is changed.

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/features/study/new_chapter_dialog.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late NewChapter? answered;

  Future<void> ask(WidgetTester tester) async {
    answered = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                answered = await showNewChapterDialog(context),
            child: const Text('Ask'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
  }

  testWidgets('the name is typed without clicking the field, and Enter '
      'creates the chapter', (tester) async {
    await ask(tester);
    tester.testTextInput.enterText('Queen endings');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(answered?.name, 'Queen endings');
    expect(answered?.root, Fen.initial);
  });

  testWidgets('an empty name is refused, and the refusal goes once the '
      'name is typed', (tester) async {
    await ask(tester);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Please enter a name.'), findsOneWidget);
    expect(answered, isNull);

    await tester.enterText(find.widgetWithText(TextField, 'Chapter name'), 'Q');
    await tester.pump();
    expect(find.text('Please enter a name.'), findsNothing);
  });
}
