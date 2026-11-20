// Send to Lichess: what the dialog says a send came to, the link it checks
// for an existing study, and where a send that stopped goes next.

import 'dart:async';

import 'package:chess_auto_prep/features/study/study_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_study_writer.dart';
import '../../support/study_fixture.dart';

const _oneChapter = '''
[Event "Endgames: Rook endings"]
[Result "*"]
[StudyName "Endgames"]
[ChapterName "Rook endings"]
[Orientation "white"]

1. e4 e5 2. Nf3 *
''';

void main() {
  late ScriptedStudyWriter lichess;
  late StudyFixture study;

  Future<void> sendAgain(WidgetTester tester) async {
    unawaited(
      sendStudyToLichess(
        tester.element(find.byType(Scaffold)),
        study.studies,
        study.session,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSend(WidgetTester tester, String text) async {
    lichess = ScriptedStudyWriter();
    study = await openStudy(text, lichessWriter: lichess);
    addTearDown(study.dispose);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await sendAgain(tester);
  }

  FilledButton button(WidgetTester tester, String label) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

  testWidgets('one chapter sent says it was added, and sent again that it '
      'was updated', (tester) async {
    await openSend(tester, _oneChapter);
    expect(find.text('1 chapter of “Endgames”'), findsOneWidget);
    await tester.tap(find.text('Send 1 chapter'));
    await tester.pumpAndSettle();
    expect(
      find.text('Sent to lichess.org/study/wxyz9876 · 1 added'),
      findsOneWidget,
    );
    expect(find.textContaining('not read whole'), findsNothing);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await sendAgain(tester);
    await tester.tap(find.text('Send 1 chapter'));
    await tester.pumpAndSettle();
    expect(
      find.text('Sent to lichess.org/study/wxyz9876 · 1 updated'),
      findsOneWidget,
    );
    expect(lichess.created, hasLength(1));
  });

  testWidgets('once sent, where it went can no longer be changed', (
    tester,
  ) async {
    await openSend(tester, _oneChapter);
    await tester.tap(find.text('Send 1 chapter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Existing study'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Lichess study link'), findsNothing);
  });

  testWidgets('a chapter not read whole stays here, and the dialog says so', (
    tester,
  ) async {
    await openSend(
      tester,
      twoChapterStudy.replaceFirst('1. d4 d5 *', '1. d4 e9 *'),
    );
    await tester.tap(find.text('Send 2 chapters'));
    await tester.pumpAndSettle();
    expect(lichess.added.map((a) => a.name), ['Rook endings']);
    expect(
      find.text('1 chapter was not read whole and stayed here.'),
      findsOneWidget,
    );
  });

  testWidgets('an existing study\'s link is checked as it is typed', (
    tester,
  ) async {
    await openSend(tester, twoChapterStudy);
    await tester.tap(find.text('Existing study'));
    await tester.pumpAndSettle();
    const wrong = 'Use a link to a Lichess study.';
    final link = find.widgetWithText(TextField, 'Lichess study link');
    expect(find.text(wrong), findsNothing, reason: 'nothing typed yet');
    expect(button(tester, 'Send 2 chapters').onPressed, isNull);

    await tester.enterText(link, 'nonsense');
    await tester.pump();
    expect(find.text(wrong), findsOneWidget);

    await tester.enterText(link, 'https://lichess.org/study/abcd1234');
    await tester.pump();
    expect(find.text(wrong), findsNothing);
    expect(button(tester, 'Send 2 chapters').onPressed, isNotNull);
  });

  testWidgets('a send that stopped after making the study goes back to that '
      'study, not a new one', (tester) async {
    await openSend(tester, twoChapterStudy);
    lichess.refuse.add('Pawn endings');
    await tester.tap(find.text('Send 2 chapters'));
    await tester.pumpAndSettle();
    expect(lichess.created, ['Endgames']);
    expect(
      find.widgetWithText(TextField, 'https://lichess.org/study/wxyz9876'),
      findsOneWidget,
    );

    lichess.refuse.clear();
    await tester.tap(find.text('Send again'));
    await tester.pumpAndSettle();
    expect(lichess.created, hasLength(1));
    expect(lichess.added.map((a) => a.name), ['Rook endings', 'Pawn endings']);
    expect(lichess.added.map((a) => a.study).toSet(), {'wxyz9876'});
  });
}
