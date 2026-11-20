import 'dart:async';

import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/study_lichess.dart';
import 'package:chess_auto_prep/features/study/study_actions.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'retrying a study upload after shutdown adds the acknowledged chapter only once',
    () async {
      final waiting = Completer<void>();
      final release = Completer<void>();
      final writer = ScriptedStudyWriter()
        ..beforeAdd = (name) async {
          if (name == 'Pawn endings') {
            waiting.complete();
            await release.future;
          }
        };
      final w = WindowFixture(
        lichessWriter: writer,
        exitWait: const Duration(minutes: 1),
      );
      addTearDown(w.dispose);
      final ref = studyRef('Endgames');
      w.store.documents[ref] = Opened(
        twoChapterStudy,
        scriptedRevision(twoChapterStudy),
      );
      w.studyFiles.listing = StudiesListed([ref]);
      await w.requests.openStudy(ref);
      expect(w.session.source, ref);
      final sending = w.studies.sender!.send(into: writer.studyId);
      await waiting.future;
      expect(writer.added.map((a) => a.name), ['Rook endings']);
      w.parts.prepareToClose();
      final closing = w.parts.exit.mayClose().then((allowed) {
        expect(allowed, isTrue);
        final persisted = (w.store.documents[ref]! as Opened).text;
        w.dispose();
        return persisted;
      });
      await pumpEventQueue();
      release.complete();
      final savedAtClose = await closing;
      await sending;

      writer.beforeAdd = null;
      final reopened = await openStudy(savedAtClose, lichessWriter: writer);
      addTearDown(reopened.dispose);
      await reopened.studies.sender!.send(into: writer.studyId);
      expect(writer.added.where((a) => a.name == 'Rook endings'), hasLength(1));
      expect(writer.replaced.map((r) => r.chapter), contains('chap0000'));
    },
  );

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
    await w.requests.openStudy(ref);
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
    await w.requests.openStudy(ref);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Send to Lichess…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send 2 chapters'));
    await tester.pumpAndSettle();
    expect(find.text('Log in to Lichess to send a study.'), findsOneWidget);
    expect(find.text('Send again'), findsOneWidget);
    expect(lichess.created, isEmpty);
  });

  testWidgets('logging in waits for an existing study link before sending', (
    tester,
  ) async {
    final lichess = ScriptedStudyWriter(loggedIn: false);
    final study = await openStudy(twoChapterStudy, lichessWriter: lichess);
    addTearDown(study.dispose);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    unawaited(
      sendStudyToLichess(
        tester.element(find.byType(Scaffold)),
        study.studies,
        study.session,
        onLogIn: (_) async {
          lichess.loggedIn = true;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send 2 chapters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Existing study'));
    await tester.pumpAndSettle();
    final retry = find.widgetWithText(FilledButton, 'Send again');
    expect(tester.widget<FilledButton>(retry).onPressed, isNull);

    await tester.tap(find.text('Log in to Lichess…'));
    await tester.pumpAndSettle();
    expect(lichess.loggedIn, isTrue);
    expect(lichess.created, isEmpty);
    expect(lichess.added, isEmpty);
    expect(find.text('Log in to Lichess to send a study.'), findsNothing);
    expect(find.text('Log in to Lichess…'), findsNothing);
    final send = find.widgetWithText(FilledButton, 'Send 2 chapters');
    expect(tester.widget<FilledButton>(send).onPressed, isNull);

    final link = find.byType(TextField);
    await tester.enterText(link, 'https://lichess.org/study/');
    await tester.pump();
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.enterText(link, 'https://lichess.org/study/abcd1234');
    await tester.pump();
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(lichess.created, isEmpty);
    expect(lichess.added.map((a) => a.study), ['abcd1234', 'abcd1234']);
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
    await w.requests.openStudy(ref);
    await tester.pumpAndSettle();
    expect(find.text('Send to Lichess…'), findsNothing);
  });
}
