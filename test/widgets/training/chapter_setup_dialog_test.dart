import 'package:chess_auto_prep/models/training_settings.dart';
import 'package:chess_auto_prep/services/training/chapter_layout.dart';
import 'package:chess_auto_prep/widgets/training/chapter_setup_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChapterLayoutProposal _proposal(int chapterCount) => ChapterLayoutProposal(
  mode: ChapterGroupingMode.auto,
  formatLabel: 'a course export',
  explanation: 'Every game names its chapter in the [White] header.',
  chapters: [
    for (var i = 0; i < chapterCount; i++)
      ChapterSummary(name: 'Chapter $i', lineCount: i + 1),
  ],
  ungroupedLineCount: 12,
);

void main() {
  // Regression: the chapter list is a lazy viewport, and AlertDialog measures
  // its content through an IntrinsicWidth. With a loose `maxWidth` the query
  // reached the viewport and threw, which left the dialog's render box without
  // a size — after which every hit test threw, MouseTracker stayed stuck in
  // its device-update phase, and the whole app stopped taking pointer input.
  testWidgets('lays out with a long chapter list and no exceptions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showChapterSetupDialog(
                  context,
                  // 37 chapters is what a real Chessable course export
                  // produces; one screenful is not enough to force scrolling.
                  proposal: _proposal(37),
                  chaptersCurrentlyOn: false,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Looks like a course export'), findsOneWidget);
    expect(find.text('Sort 703 lines into these 37 chapters?'), findsOneWidget);
    expect(find.text('Sort into chapters'), findsOneWidget);

    // The dialog must be hit-testable: a sizeless render box is exactly the
    // failure mode this test exists for.
    await tester.tap(find.text('Sort into chapters'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Looks like a course export'), findsNothing);
  });
}
