import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/study_lichess.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/scripted_study_writer.dart';
import '../support/study_fixture.dart';
import '../support/window_fixture.dart';

/// The end of the plane scenario: the study made offline goes to Lichess
/// from the Study panel, and comes back to the same Lichess study after.
void main() {
  testWidgets('Send to Lichess makes the study there, says where, opens it, '
      'and the next send goes back to it', (tester) async {
    final lichess = ScriptedStudyWriter();
    final w = WindowFixture(lichessWriter: lichess);
    addTearDown(w.dispose);
    final ref = studyRef('Endgames');
    w.store.documents[ref] = Opened(
      twoChapterStudy,
      scriptedRevision(twoChapterStudy),
    );
    w.studyFiles.listing = StudiesListed([ref]);
    await w.pumpShell(tester);
    await w.requests.openStudy(ref, chapter: 0);
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.study);

    await tester.tap(find.widgetWithText(TextButton, 'Send to Lichess…'));
    await tester.pumpAndSettle();
    expect(find.text('2 chapters of “Endgames”'), findsOneWidget);
    expect(
      find.text('Makes a private study on your Lichess account.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Send 2 chapters'));
    await tester.pumpAndSettle();

    expect(lichess.created, ['Endgames']);
    expect(lichess.added.map((a) => a.name), ['Rook endings', 'Pawn endings']);
    expect(
      find.text('Sent to lichess.org/study/wxyz9876 · 2 added'),
      findsOneWidget,
    );
    await tester.tap(find.text('Open on Lichess'));
    await tester.pumpAndSettle();
    expect(w.openedPages, [Uri.parse('https://lichess.org/study/wxyz9876')]);
    expect(
      tagValue(w.session.chapter!.lines.first.tags, chapterUrlTag),
      'https://lichess.org/study/wxyz9876/chap0000',
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Again: the study the chapters went to is where they go back.
    await tester.tap(find.widgetWithText(TextButton, 'Send to Lichess…'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextField, 'https://lichess.org/study/wxyz9876'),
      findsOneWidget,
    );
    await tester.tap(find.text('Send 2 chapters'));
    await tester.pumpAndSettle();
    expect(lichess.created, hasLength(1));
    expect(lichess.replaced.map((r) => r.chapter), ['chap0000', 'chap1000']);
    expect(
      find.text('Sent to lichess.org/study/wxyz9876 · 2 updated'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('signed out, the dialog says to log in and sends nothing', (
    tester,
  ) async {
    final lichess = ScriptedStudyWriter(loggedIn: false);
    final w = WindowFixture(lichessWriter: lichess);
    addTearDown(w.dispose);
    final ref = studyRef('Endgames');
    w.store.documents[ref] = Opened(
      twoChapterStudy,
      scriptedRevision(twoChapterStudy),
    );
    w.studyFiles.listing = StudiesListed([ref]);
    await w.pumpShell(tester);
    await w.requests.openStudy(ref, chapter: 0);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Send to Lichess…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send 2 chapters'));
    await tester.pumpAndSettle();
    expect(find.text('Log in to Lichess to send a study.'), findsOneWidget);
    expect(find.text('Send again'), findsOneWidget);
    expect(lichess.created, isEmpty);
  });

  testWidgets('without a way to write to Lichess there is no Send', (
    tester,
  ) async {
    final w = WindowFixture();
    addTearDown(w.dispose);
    final ref = studyRef('Endgames');
    w.store.documents[ref] = Opened(
      twoChapterStudy,
      scriptedRevision(twoChapterStudy),
    );
    w.studyFiles.listing = StudiesListed([ref]);
    await w.pumpShell(tester);
    await w.requests.openStudy(ref, chapter: 0);
    await tester.pumpAndSettle();
    expect(find.text('Send to Lichess…'), findsNothing);
  });
}
