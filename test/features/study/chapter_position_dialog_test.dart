// Move to position: a chapter can be moved to the top of its study.

import 'package:chess_auto_prep/features/study/study_panel.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/status_host.dart';
import '../../support/study_fixture.dart';

void main() {
  testWidgets('the last chapter moved to position 1 becomes the first', (
    tester,
  ) async {
    final study = await openStudy(threeChapterStudy, name: 'Openings');
    addTearDown(study.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: StudyPanel(
              studies: study.studies,
              session: study.session,
              onOpen: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Chapter actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to position…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.tap(find.text('Move'));
    await tester.pumpAndSettle();
    expect([for (final c in study.studies.chapters) c.name], [
      'Gamma',
      'Alpha',
      'Beta',
    ]);
  });
}
