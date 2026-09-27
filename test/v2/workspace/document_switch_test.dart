// Another document asked for while this one is still being written: words
// typed while the next one is read, an undo that crosses an open, a copy
// that lands after the user went somewhere else. Whatever order the answers
// come back in, the words reach the file they were typed into, and the
// screen shows what that file holds.
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    show IoFailure, Opened, SaveRefused;
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

void main() {
  final sicilian = NodePath.of([0]);
  final other = chapterRef('KID', 'Other');

  /// A chapter open with a clock long enough that an edit is still waiting
  /// on it while the test does something else, and [other] beside it.
  Future<SessionFixture> slowSession() async {
    final fixture = await openSession(
      blackChapter,
      delay: const Duration(seconds: 5),
    );
    addTearDown(fixture.dispose);
    fixture.store.documents[other] = Opened(
      whiteChapter,
      scriptedRevision(whiteChapter),
    );
    return fixture;
  }

  group('words typed while another document is read', () {
    test('reach the file they were typed into', () async {
      final fixture = await slowSession();
      fixture.store.hold = true;
      final opening = fixture.session.open(other);
      await pumpEventQueue();
      expect(fixture.store.waiting, 1, reason: 'the read is with the store');

      fixture.session.setComment(sicilian, 'typed while it opened');
      fixture.store.hold = false;
      fixture.store.releaseAll();

      expect(await opening, isA<DocumentOpened>());
      expect(fixture.onDisk, contains('{typed while it opened [%eval 0.30]}'));
      expect(fixture.session.source, other);
      expect(fixture.saver.state, isA<Saved>());
    });

    test('that the file will not take keep their document up', () async {
      final fixture = await slowSession();
      fixture.store.hold = true;
      final opening = fixture.session.open(other);
      await pumpEventQueue();

      fixture.session.setComment(sicilian, 'typed while it opened');
      fixture.store.saves.add(const IoFailure('No space left on device'));
      fixture.store.hold = false;
      fixture.store.releaseAll();

      expect(await opening, isA<OpenOvertaken>());
      expect(fixture.session.source, fixture.ref);
      expect(
        fixture.session.commentAt(sicilian),
        'typed while it opened [%eval 0.30]',
        reason: 'the words are on screen, where the strip says why',
      );
      expect(fixture.saver.state, isA<SaveFailed>());
    });

    test('into the file being opened are in what it shows', () async {
      const path = '/repertoires/Course/Course.pgn';
      final open = ChapterRef.at(path, section: 'Open games');
      final alapin = ChapterRef.at(path, section: 'Sicilian');
      final store = ScriptedDocumentStore()
        ..documents[ChapterRef.at(path)] = Opened(
          courseFile,
          scriptedRevision(courseFile),
        );
      final saver = DocumentSaver(store, delay: const Duration(seconds: 5));
      final session = DocumentSession(store, saver);
      addTearDown(() {
        session.dispose();
        saver.dispose();
      });
      await session.open(open);
      store.hold = true;
      final opening = session.open(alapin);
      await pumpEventQueue();

      session.setComment(NodePath.of([0]), 'the king pawn');
      store.hold = false;
      store.releaseAll();

      expect(await opening, isA<DocumentOpened>());
      expect(session.source, alapin);
      // The chapter opened was read again after the words went in, so its
      // next save is made against the file as it is now.
      session.toEnd();
      session.playMove('d7d5');
      await saver.flush();
      expect(saver.state, isA<Saved>());
      final text = (store.documents[ChapterRef.at(path)]! as Opened).text;
      expect(text, contains('{the king pawn}'));
      expect(text, contains('1. e4 c5 2. c3 d5 *'));
    });
  });

  group('an undo and an open', () {
    test('an undo asked for while another document opens is refused and '
        'changes nothing', () async {
      final fixture = await openSession(blackChapter);
      addTearDown(fixture.dispose);
      fixture.store.documents[other] = Opened(
        whiteChapter,
        scriptedRevision(whiteChapter),
      );
      fixture.session.setComment(sicilian, 'B');
      await pumpEventQueue();
      fixture.store.hold = true;
      final opening = fixture.session.open(other);
      await pumpEventQueue();

      final undoing = fixture.session.undo();
      await pumpEventQueue();
      fixture.store.hold = false;
      fixture.store.releaseAll();

      expect(await undoing, isA<UndoRefused>());
      expect(await opening, isA<DocumentOpened>());
      expect(
        fixture.onDisk,
        contains('{B [%eval 0.30]}'),
        reason: 'the file being left keeps its last edit',
      );
      expect(fixture.store.requestedSaves, hasLength(1));
    });

    test('an undo that lands while another document fails to open is '
        'shown', () async {
      final fixture = await openSession(blackChapter);
      addTearDown(fixture.dispose);
      fixture.session.setComment(sicilian, 'B');
      await pumpEventQueue();
      fixture.store.hold = true;
      final undoing = fixture.session.undo();
      await pumpEventQueue();
      final opening = fixture.session.open(chapterRef('KID', 'Gone'));
      await pumpEventQueue();
      fixture.store.hold = false;
      fixture.store.releaseAll();

      expect(await undoing, isA<Restored>());
      expect(await opening, isA<OpenFailed>());
      expect(fixture.session.source, fixture.ref);
      expect(
        fixture.session.commentAt(sicilian),
        'The Sicilian [%eval 0.30]',
        reason: 'the screen shows what the file holds',
      );
    });

    test('an undo asked for as the analysis board comes up is refused and '
        'changes nothing', () async {
      final fixture = await openSession(blackChapter);
      addTearDown(fixture.dispose);
      fixture.session.setComment(sicilian, 'B');
      await pumpEventQueue();

      final board = fixture.session.showAnalysisBoard();
      final undoing = fixture.session.undo();

      expect(await undoing, isA<UndoRefused>());
      expect(await board, isTrue);
      await pumpEventQueue();
      expect(
        fixture.onDisk,
        contains('{B [%eval 0.30]}'),
        reason: 'the file being left keeps its last edit',
      );
    });
  });

  group('the analysis board', () {
    test('says it is up, when it already was too', () async {
      final fixture = await openSession(blackChapter);
      addTearDown(fixture.dispose);
      expect(await fixture.session.showAnalysisBoard(), isTrue);
      expect(fixture.session.isScratch, isTrue);
      expect(await fixture.session.showAnalysisBoard(), isTrue);
    });

    test('says it is not up when a document was opened meanwhile', () async {
      final fixture = await openSession(blackChapter);
      addTearDown(fixture.dispose);
      fixture.store.documents[other] = Opened(
        whiteChapter,
        scriptedRevision(whiteChapter),
      );
      fixture.store.hold = true;
      fixture.session.setComment(sicilian, 'B');
      await pumpEventQueue(); // the save is held, so the board waits for it
      final board = fixture.session.showAnalysisBoard();
      final opening = fixture.session.open(other);
      fixture.store.hold = false;
      fixture.store.releaseAll();

      expect(await board, isFalse);
      expect(await opening, isA<DocumentOpened>());
      expect(fixture.session.source, other);
    });
  });

  group('a copy of a frozen document', () {
    test('does not take over a document opened while it was written', () async {
      final fixture = await openSession(blackChapter);
      addTearDown(fixture.dispose);
      fixture.store.documents[other] = Opened(
        whiteChapter,
        scriptedRevision(whiteChapter),
        readOnly: 'it is not UTF-8',
      );
      fixture.store.saves.add(const SaveRefused('game 3 would change'));
      fixture.session.setComment(sicilian, 'one');
      await pumpEventQueue();
      expect(fixture.saver.state, isA<SaveStopped>());

      fixture.store.hold = true;
      final copying = fixture.session.saveCopy('Main draft');
      await pumpEventQueue(); // the copy is with the store
      fixture.store.hold = false;
      expect(await fixture.session.open(other), isA<DocumentOpened>());
      fixture.store.releaseAll();

      final copied = await copying as CopySaved;
      expect(copied.name, 'Main draft.pgn');
      expect(copied.nowEditing, isFalse);
      expect(fixture.session.source, other, reason: 'the user went there');
    });

    test('takes over the document it copied', () async {
      final fixture = await openSession(blackChapter);
      addTearDown(fixture.dispose);
      fixture.store.saves.add(const SaveRefused('game 3 would change'));
      fixture.session.setComment(sicilian, 'one');
      await pumpEventQueue();

      final copied = await fixture.session.saveCopy('Main draft') as CopySaved;

      expect(copied.nowEditing, isTrue);
      expect(fixture.session.source?.path, '/repertoires/KID/Main draft.pgn');
    });
  });
}

/// Three games of one file in two chapters named by tag.
const courseFile = '''
// Color: White

[Event "Ruy"]
[ChapterName "Open games"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 *

[Event "Alapin"]
[ChapterName "Sicilian"]

1. e4 c5 2. c3 *

[Event "Italian"]
[ChapterName "Open games"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 *
''';
