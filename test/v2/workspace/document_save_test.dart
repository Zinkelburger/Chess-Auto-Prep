import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    show Collision, Conflict, IoFailure, Opened;
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

void main() {
  late SessionFixture fixture;
  late DocumentSession session;
  late DocumentSaver saver;
  final sicilian = NodePath.of([0]);

  setUp(() async {
    fixture = await openSession(blackChapter);
    session = fixture.session;
    saver = fixture.saver;
  });

  tearDown(() => fixture.dispose());

  /// Comments the first move, which is one edit of the file.
  void edit(String words) => session.setComment(sicilian, words);

  test('an edit is saved at once and says so', () async {
    expect(saver.state, isA<Saved>());
    edit('one');
    expect(saver.state, isA<Saving>());
    await pumpEventQueue();
    expect(saver.state, isA<Saved>());
    expect(fixture.onDisk, contains('{one [%eval 0.30]}'));
  });

  test('edits during a save collapse into one save of the newest', () async {
    fixture.store.hold = true;
    edit('one');
    edit('two');
    edit('three');
    expect(fixture.store.requestedSaves, hasLength(1));
    expect(saver.state, isA<Unsaved>());
    fixture.store.releaseAll();
    await pumpEventQueue();
    expect(fixture.store.requestedSaves, hasLength(2));
    fixture.store.releaseAll();
    await pumpEventQueue();
    expect(saver.state, isA<Saved>());
    expect(fixture.onDisk, contains('{three [%eval 0.30]}'));
    expect(fixture.onDisk, isNot(contains('two')));
  });

  test('flush waits for the newest draft to reach the file', () async {
    fixture.store.hold = true;
    edit('one');
    edit('two'); // collapses behind the write already going out
    var landed = false;
    final flushed = saver.flush().then((_) => landed = true);
    await pumpEventQueue();
    expect(landed, isFalse);
    fixture.store.releaseAll(); // the first write
    await pumpEventQueue();
    expect(landed, isFalse, reason: 'the newest text is still on its way');
    fixture.store.releaseAll(); // the second
    await flushed;
    expect(saver.state, isA<Saved>());
    expect(fixture.onDisk, contains('{two [%eval 0.30]}'));
  });

  test('a draft on its way out lands before another chapter opens', () async {
    final other = chapterRef('KID', 'Other');
    fixture.store.documents[other] = Opened(
      whiteChapter,
      scriptedRevision(whiteChapter),
    );
    fixture.store.hold = true;
    edit('one');
    final opening = session.open(other);
    await pumpEventQueue();
    expect(session.source, fixture.ref, reason: 'it waits for the draft');
    fixture.store.releaseAll(); // the save for the chapter being left
    await pumpEventQueue();
    fixture.store.releaseAll(); // then the read of the new one
    expect(await opening, isA<DocumentOpened>());
    expect(fixture.onDisk, contains('{one [%eval 0.30]}'));
    expect(
      saver.canUndo,
      isFalse,
      reason: 'the receipt belongs to the chapter that was left',
    );
    expect(saver.state, isA<Saved>());
  });

  test('reloading takes the text the draft going out wrote', () async {
    fixture.store.hold = true;
    edit('one');
    final reopening = session.reloadFromDisk();
    await pumpEventQueue();
    fixture.store.releaseAll(); // the save lands first
    await pumpEventQueue();
    fixture.store.releaseAll(); // then the read, which sees it
    expect(await reopening, isA<DocumentOpened>());
    expect(session.commentAt(sicilian), 'one [%eval 0.30]');
    fixture.store.hold = false;
    edit('two');
    await pumpEventQueue();
    expect(
      saver.state,
      isA<Saved>(),
      reason: 'the document knows the revision its own write committed',
    );
    expect(fixture.onDisk, contains('{two [%eval 0.30]}'));
  });

  test('a hold whose action throws does not poison the saver', () async {
    await expectLater(
      saver.holdStill((_) => Future<void>.error(StateError('no'))),
      throwsStateError,
    );
    // The failure was the caller's, once. Flushing and holding again must not
    // hand it out for the rest of the document's life.
    await saver.flush();
    expect(await saver.holdStill((_) async => 'ok'), 'ok');
    edit('one');
    await saver.flush();
    expect(fixture.onDisk, contains('{one [%eval 0.30]}'));
  });

  test('a conflict keeps no draft waiting behind it', () async {
    edit('A');
    await pumpEventQueue();
    fixture.store.hold = true;
    edit('B'); // goes out
    edit('C'); // waits behind it
    fixture.externalEdit('// Color: Black\n\n1. d4 *\n');
    fixture.store.releaseAll();
    await pumpEventQueue();
    expect(saver.state, isA<SaveConflict>());
    fixture.store.hold = false;
    fixture.store.requestedSaves.clear();
    expect(await saver.undo(), isA<UndoRefused>());
    expect(
      fixture.store.requestedSaves,
      hasLength(1),
      reason: 'the undo was asked for, not refused over a draft nobody wants',
    );
  });

  test('a conflict keeps the draft and stops writing', () async {
    fixture.externalEdit('// Color: Black\n\n1. d4 *\n');
    edit('one');
    await pumpEventQueue();
    expect(saver.state, isA<SaveConflict>());
    expect(session.commentAt(sicilian), 'one [%eval 0.30]');
    fixture.store.requestedSaves.clear();
    edit('two');
    await pumpEventQueue();
    expect(fixture.store.requestedSaves, isEmpty);
    expect(saver.state, isA<SaveConflict>());
  });

  test('a failed save keeps the draft and the next edit retries', () async {
    fixture.store.saves.add(const IoFailure('No space left on device'));
    edit('one');
    await pumpEventQueue();
    expect((saver.state as SaveFailed).detail, 'No space left on device');
    expect(session.commentAt(sicilian), 'one [%eval 0.30]');
    edit('two');
    await pumpEventQueue();
    expect(saver.state, isA<Saved>());
    expect(fixture.onDisk, contains('{two [%eval 0.30]}'));
  });

  test('undo takes the edits back one at a time', () async {
    final first = fixture.onDisk;
    edit('B');
    await pumpEventQueue();
    final second = fixture.onDisk;
    edit('C');
    await pumpEventQueue();
    await session.undo();
    expect(fixture.onDisk, second);
    expect(session.commentAt(sicilian), 'B [%eval 0.30]');
    await session.undo();
    expect(fixture.onDisk, first);
    expect(session.commentAt(sicilian), 'The Sicilian [%eval 0.30]');
    expect(saver.canUndo, isFalse);
    expect(saver.state, isA<Saved>());
  });

  test('an undo the document has left behind refuses and saves on', () async {
    edit('B');
    await pumpEventQueue();
    // The store refuses and names the revision the document already has: it
    // is the entry that is out of date, not the file.
    fixture.store.saves.add(Conflict(scriptedRevision(fixture.onDisk)));
    expect(await saver.undo(), isA<UndoRefused>());
    expect(saver.state, isA<Saved>());
    expect(saver.canUndo, isTrue, reason: 'nothing was taken back');
    edit('C');
    await pumpEventQueue();
    expect(saver.state, isA<Saved>());
    expect(fixture.onDisk, contains('{C [%eval 0.30]}'));
  });

  test('an undo the file no longer expects is refused, history kept', () async {
    edit('B');
    await pumpEventQueue();
    fixture.externalEdit('// Color: Black\n\n1. d4 *\n');
    await session.undo();
    expect(saver.state, isA<SaveConflict>());
    expect(saver.canUndo, isTrue);
    expect(session.commentAt(sicilian), 'B [%eval 0.30]');
  });

  test('the cursor comes back to a move the file still has', () async {
    session.goTo(sicilian);
    session.playMove('c2c3'); // a new line, so a new branch under c5
    await pumpEventQueue();
    final added = session.cursor;
    expect(added, isNot(sicilian));
    await session.undo();
    expect(session.cursor, sicilian);
    expect(session.chapter?.gameCount, 2);
  });

  test('nothing to undo is not an error', () async {
    await session.undo();
    expect(saver.state, isA<Saved>());
  });

  test('a copy refused while another chapter opened still says so', () async {
    final other = chapterRef('KID', 'Other');
    fixture.store.documents[other] = Opened(
      whiteChapter,
      scriptedRevision(whiteChapter),
    );
    fixture.store.creates.add(const Collision());
    fixture.store.hold = true;
    final copying = session.saveCopy('Main draft');
    final opening = session.open(other);
    await pumpEventQueue();
    fixture.store.releaseAll();
    await opening;
    expect(await copying, isA<CopyNameTaken>());
  });

  group('the ways out of a conflict', () {
    const theirs = '''
// Color: Black

[Event "Theirs"]
[Result "*"]

1. e4 e5 *
''';

    setUp(() async {
      fixture.externalEdit(theirs);
      edit('mine');
      await pumpEventQueue();
      expect(saver.state, isA<SaveConflict>());
    });

    test('reloading drops the draft and takes what is on disk', () async {
      expect(await session.reloadFromDisk(), isA<DocumentOpened>());
      expect(session.chapter?.tree.children.first.san, 'e4');
      expect(saver.state, isA<Saved>());
      expect(saver.canUndo, isFalse);
    });

    test('a copy is written beside the original', () async {
      expect(await session.saveCopy('Main draft'), isA<CopySaved>());
      expect(
        fixture.store.documents.keys.map((ref) => ref.path),
        contains('/repertoires/KID/Main draft.pgn'),
      );
    });

    test('a taken name replaces nothing and says so', () async {
      fixture.store.creates.add(const Collision());
      expect(await session.saveCopy('Main'), isA<CopyNameTaken>());
    });

    test('a copy that could not be written says why', () async {
      fixture.store.creates.add(const IoFailure('Permission denied'));
      final result = await session.saveCopy('Main draft');
      expect((result as CopyFailed).detail, 'Permission denied');
    });
  });
}
