import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/study_choice.dart';
import 'package:chess_auto_prep/workspace/study_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final studies = [
    ChapterRef.at('/studies/Endgames.pgn'),
    ChapterRef.at('/studies/Openings.pgn'),
  ];

  Future<Future<StudyPick?>> open(
    WidgetTester tester, {
    String? chapter = 'Carlsen – Nakamura',
    int count = 1,
  }) async {
    late Future<StudyPick?> answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => answer = showStudyPicker(
              context,
              studies: studies,
              chapter: chapter,
              count: count,
            ),
            child: const Text('Add'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('the chapter can be renamed and a study is picked by typing', (
    tester,
  ) async {
    final answer = await open(tester);
    expect(find.text('Carlsen – Nakamura'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Carlsen – Nakamura'),
      'Najdorf trap',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Type a study'),
      'end',
    );
    await tester.pumpAndSettle();
    expect(find.text('Openings'), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final pick = (await answer)!;
    expect((pick.into as IntoStudy).study, studies.first);
    expect(pick.name, 'Najdorf trap');
  });

  testWidgets('New study asks its name; several chapters ask none', (
    tester,
  ) async {
    final answer = await open(tester, chapter: null, count: 3);
    expect(find.text('Add 3 chapters to a study'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Chapter name'), findsNothing);
    await tester.tap(find.text('New study…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Study name'),
      'Prep',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    final pick = (await answer)!;
    expect((pick.into as NewStudy).name, 'Prep');
  });
}
