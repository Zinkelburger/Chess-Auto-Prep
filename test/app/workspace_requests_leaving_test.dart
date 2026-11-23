import 'dart:async';

import 'package:chess_auto_prep/app/exit_guard.dart';
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/workspace_requests.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/reading/comment_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/study_fixture.dart';
import '../support/window_fixture.dart';

/// Leaving a document through the window's requests: the question about a
/// draft its file never took, the copy made on the way out, and Close file.
void main() {
  final kid = kidMain;
  final benko = benkoMain;

  late WindowFixture w;

  setUp(() => w = WindowFixture());

  tearDown(() => w.dispose());

  /// Opens KID and leaves a comment its file refused, so the next document
  /// has a draft to ask about.
  Future<void> freezeKid() async {
    await w.requests.open(kid);
    w.store.saves.add(const SaveRefused('game 3 would change'));
    w.session.setComment(NodePath.of([0]), 'frozen words');
    await pumpEventQueue();
  }

  group('open over a draft the file refused', () {
    test('changing study games while copying still closes the study', () async {
      final study = studyRef('Endgames');
      w.store.documents[study] = Opened(
        twoChapterStudy,
        scriptedRevision(twoChapterStudy),
      );
      await w.requests.openStudy(study);
      final changed = twoChapterStudy.replaceFirst('Nf3 *', 'Bc4 *');
      w.store.documents[study] = Opened(changed, scriptedRevision(changed));
      w.session.setComment(NodePath.of([0]), 'A note for the copy');
      await w.saver.flush();

      final gate = w.store.createGate = Completer<void>();
      w.question.answer = DraftChoice.saveACopy;
      final closing = w.requests.closeFile();
      await pumpEventQueue();
      expect(w.store.createGate, isNull);
      w.session.nextGame();
      expect(w.session.game, 1);
      gate.complete();

      expect(await closing, isA<RequestDone>());
      expect(w.session.isScratch, isTrue);
      final copy = w.store.documents[studyRef('Main copy')] as Opened;
      expect(copy.text, contains('A note for the copy'));
      expect(copy.text, contains('1. d4 d5 *'));
    });

    test('a copy of the same PGN under its old source cannot close the '
        'relocated document', () async {
      await freezeKid();
      final gate = w.store.createGate = Completer<void>();
      w.question.answer = DraftChoice.saveACopy;
      final closing = w.requests.closeFile();
      await pumpEventQueue();
      expect(w.store.createGate, isNull);
      final moved = ChapterRef.at('/repertoires/KID/Renamed.pgn');
      w.session.relocated(moved);
      gate.complete();

      expect(await closing, isA<RequestDropped>());
      expect(w.session.source, moved);
      expect(w.session.commentAt(NodePath.of([0])), contains('frozen words'));
    });

    test('an edit after the copy keeps the source open when the next file '
        'arrives', () async {
      await freezeKid();
      final gate = w.store.readEarly = Completer<void>();
      w.question.answer = DraftChoice.saveACopy;
      final opening = w.requests.open(benko);
      await pumpEventQueue();
      expect(w.store.readEarly, isNull);
      expect(w.store.opened.last, benko);
      w.session.committingEditors.addListener(
        () => w.session.setComment(NodePath.of([0]), 'After the copy'),
      );
      gate.complete();

      expect(await opening, isA<RequestDropped>());
      expect(w.session.source, kid);
      expect(w.session.commentAt(NodePath.of([0])), contains('After the copy'));
      final copy =
          w.store.documents[ChapterRef.at('/repertoires/KID/Main copy.pgn')]
              as Opened;
      expect(copy.text, contains('frozen words'));
      expect(copy.text, isNot(contains('After the copy')));
    });

    test('the chapter already open is not left, so nothing is asked', () async {
      await freezeKid();
      expect(await w.requests.open(kid), isA<RequestDone>());
      expect(w.question.asked, isEmpty);
    });

    test('staying with a frozen draft opens nothing', () async {
      await freezeKid();
      w.question.answer = DraftChoice.keepWaiting;
      expect(await w.requests.open(benko), isA<RequestDropped>());
      expect(w.question.asked.single, contains('was stopped'));
      expect(w.session.source, kid);
      expect(w.requests.status, isNull);
    });

    test(
      'staying with a frozen draft on Back keeps the mode and the history',
      () async {
        await w.requests.open(benko);
        final started = w.requests.mode;
        w.requests.switchTo(Mode.pgnViewer);
        await pumpEventQueue();
        await freezeKid();
        final back = w.requests.backTo;
        w.question.answer = DraftChoice.keepWaiting;
        expect(await w.requests.back(), isA<RequestDropped>());
        expect(w.requests.mode, Mode.pgnViewer, reason: 'not $started');
        expect(w.session.source, kid);
        expect(w.requests.backTo, same(back));
        expect(w.requests.forwardTo, isNull);
      },
    );

    test('the question on Back comes before the mode changes, and is asked '
        'once', () async {
      await w.requests.open(benko);
      final started = w.requests.mode;
      w.requests.switchTo(Mode.pgnViewer);
      await pumpEventQueue();
      await freezeKid();
      final modes = <Mode>[];
      w.requests.addListener(() => modes.add(w.requests.mode));
      w.question.answer = DraftChoice.keepWaiting;
      expect(await w.requests.back(), isA<RequestDropped>());
      expect(modes, everyElement(Mode.pgnViewer));

      w.question.answer = DraftChoice.closeAnyway;
      expect(await w.requests.back(), isA<RequestDone>());
      expect(w.requests.mode, started);
      expect(w.session.source, benko);
      expect(w.question.asked, hasLength(2), reason: 'one for each Back');
    });

    test(
      'a copy saved on the way out is said once the chapter is open',
      () async {
        await freezeKid();
        w.question.answer = DraftChoice.saveACopy;
        expect(await w.requests.open(benko), isA<RequestDone>());
        expect(w.session.source, benko);
        expect(w.requests.status, 'Saved a copy as Main copy.pgn');
        expect(
          w.store.documents.keys.map((ref) => ref.path),
          contains('/repertoires/KID/Main copy.pgn'),
        );
      },
    );

    test('a copy on the way out that could not be written says why, and '
        'the chapter stays', () async {
      await freezeKid();
      w.question.answer = DraftChoice.saveACopy;
      w.store.creates.add(const IoFailure('disk full'));
      expect(await w.requests.open(benko), isA<RequestDropped>());
      expect(w.session.source, kid);
      expect(w.requests.status, 'Could not save a copy: disk full');

      w.store.creates.add(const Collision());
      expect(await w.requests.open(benko), isA<RequestDropped>());
      expect(w.requests.status, 'That name is taken. Nothing was replaced.');
    });
  });

  group('Close file', () {
    final study = studyRef('Endgames');
    final move = NodePath.of([0]);
    final note = find.byType(TextField);

    Future<void> openStudy() async {
      w.store.documents[study] = Opened(
        twoChapterStudy,
        scriptedRevision(twoChapterStudy),
      );
      await w.requests.openStudy(study);
    }

    Future<void> editNote(WidgetTester tester) async {
      await openStudy();
      w.session.cursor.goTo(move);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CommentField(session: w.session)),
        ),
      );
    }

    test('with nothing open does nothing', () async {
      expect(await w.requests.closeFile(), isA<RequestDropped>());
      expect(w.question.asked, isEmpty);
    });

    testWidgets('saves a study note typed while closing waits for a save', (
      tester,
    ) async {
      await editNote(tester);
      await tester.enterText(note, 'Occupy the centre');
      w.store.hold = true;
      w.session.cursor.forward(); // Leaving e4 commits its note.
      await tester.pump();
      expect(w.store.requestedSaves.single.text, contains('Occupy the centre'));

      final closing = w.requests.closeFile();
      await tester.enterText(note, 'Contest the centre');
      w.store
        ..hold = false
        ..releaseAll();
      expect(await closing, isA<RequestDone>());
      await tester.pump(w.exitWait);

      final written = (w.store.documents[study]! as Opened).text;
      expect(written, contains('e4 {Occupy the centre}'));
      expect(written, contains('e5 {Contest the centre}'));
    });

    testWidgets('closes the same study after its rename lands', (tester) async {
      await editNote(tester);
      w.store.hold = true;
      final rename = w.studies.rename(study, 'Rook endings');
      await tester.pump();
      expect(w.saver.referencesPending, isTrue);

      final closing = w.requests.closeFile();
      await tester.enterText(note, 'Follow the study');
      w.store
        ..hold = false
        ..releaseAll();
      await rename;
      expect(await closing, isA<RequestDone>());
      final renamed = w.store.documents[studyRef('Rook endings')]! as Opened;
      expect(renamed.text, contains('e4 {Follow the study}'));
      expect(w.session.source, isNull);
      expect(w.question.asked, isEmpty);
      await tester.pump(w.exitWait);
    });

    testWidgets('stays open when the note changed after the copy was asked '
        'for', (tester) async {
      await editNote(tester);
      w.question.answer = DraftChoice.saveACopy;
      w.store
        ..hold = true
        ..saves.add(const Conflict(null));
      w.session.setComment(move, 'First draft');
      final closing = w.requests.closeFile();
      await tester.pump();
      expect(w.store.requestedSaves.single.text, contains('First draft'));
      await tester.enterText(note, 'Updated note');
      w.store
        ..hold = false
        ..releaseAll();

      // The copy holds what was asked about; the words typed since are
      // still on screen, with their document, to be decided about.
      expect(await closing, isA<RequestDropped>());
      final copy = w.store.documents[studyRef('Main copy')]! as Opened;
      expect(copy.text, contains('e4 {First draft}'));
      expect(w.question.asked, hasLength(1));
      expect(
        w.requests.status,
        'Saved a copy as Main copy.pgn. The document changed while it was '
        'written, so it is still open.',
      );
      expect(w.session.source, study);
      expect(w.session.commentAt(move), 'Updated note');
      await tester.pump(w.exitWait);
    });

    testWidgets('keeps edits made after the copy started', (tester) async {
      await openStudy();
      final gate = w.store.createGate = Completer<void>();
      w.store.saves.add(const Conflict(null));
      w.question.answer = DraftChoice.saveACopy;
      w.session.setComment(move, 'Copied note');
      final closing = w.requests.closeFile();
      await tester.pump();
      expect(w.store.createGate, isNull);
      w.session.setComment(move, 'Later note');
      w.question.answer = DraftChoice.keepWaiting;
      gate.complete();

      expect(await closing, isA<RequestDropped>());
      final copy = w.store.documents[studyRef('Main copy')]! as Opened;
      expect(copy.text, contains('e4 {Copied note}'));
      expect(w.question.asked, hasLength(1));
      expect(w.session.source, study);
      expect(w.session.commentAt(move), 'Later note');
      await tester.pump(w.exitWait);
    });

    testWidgets('a reload at the same path supersedes close', (tester) async {
      await openStudy();
      final gate = w.store.createGate = Completer<void>();
      w.store.saves.add(const Conflict(null));
      w.question.answer = DraftChoice.saveACopy;
      w.session.setComment(move, 'Before reload');
      final closing = w.requests.closeFile();
      await tester.pump();
      expect(w.store.createGate, isNull);
      await w.session.reloadFromDisk();
      gate.complete();
      expect(await closing, isA<RequestDropped>());
      expect(w.session.source, study);
      expect(w.question.asked, hasLength(1));
      await tester.pump(w.exitWait);
    });

    testWidgets('keeps a refused note in the field until corrected', (
      tester,
    ) async {
      await editNote(tester);
      w.store.hold = true;
      w.session.setComment(move, 'On disk');
      final closing = w.requests.closeFile();
      await tester.enterText(note, 'On disk [%note }]');
      w.store
        ..hold = false
        ..releaseAll();

      expect(await closing, isA<RequestDropped>());
      expect(w.session.source, study);
      expect(
        tester.widget<TextField>(note).controller!.text,
        'On disk [%note }]',
      );
      expect(await w.requests.closeFile(), isA<RequestDropped>());
      await tester.enterText(note, 'Corrected');
      expect(await w.requests.closeFile(), isA<RequestDone>());
      expect(
        (w.store.documents[study]! as Opened).text,
        contains('e4 {Corrected}'),
      );
      await tester.pump(w.exitWait);
    });

    test('over a draft the user stays with keeps it', () async {
      await freezeKid();
      w.question.answer = DraftChoice.keepWaiting;
      expect(await w.requests.closeFile(), isA<RequestDropped>());
      expect(w.session.source, kid);
    });
  });
}
