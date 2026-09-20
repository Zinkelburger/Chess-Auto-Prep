import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    show Collision, IoFailure, Opened, SaveRefused, WriteUnverified;
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/save_state.dart';
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

  /// The games the last save told the store it was writing again.
  Set<int> declared() =>
      (fixture.store.requestedSaves.last.scope as GamesEdited)
          .written
          .rewritten;

  test('a save names the games it writes again', () async {
    // 1... c5 is played by both lines and commented only in the first, so
    // the words go where they already lived; 2. Nc3 is the second line's.
    edit('shared');
    await pumpEventQueue();
    expect(declared(), {0});
    session.setComment(NodePath.of([0, 1]), 'the closed line');
    await pumpEventQueue();
    expect(declared(), {1});
  });

  test('a save that failed is written again with the next edit, under both '
      'their games', () async {
    fixture.store.saves.add(const IoFailure('no space left on device'));
    session.setComment(NodePath.of([0, 0]), 'first');
    await pumpEventQueue();
    expect(saver.state, isA<SaveFailed>());
    session.setComment(NodePath.of([0, 1]), 'second');
    await pumpEventQueue();
    expect(saver.state, isA<Saved>());
    expect(declared(), {0, 1});
    expect(fixture.onDisk, contains('{first}'));
    expect(fixture.onDisk, contains('{second}'));
  });

  test('a save the store stopped is not tried again, and the next edit goes '
      'out on its own', () async {
    fixture.store.saves.add(
      const SaveRefused('game 3 would change but the edit was to game 1'),
    );
    edit('one');
    await pumpEventQueue();
    expect(saver.state, isA<SaveStopped>());
    expect(saver.settled, isFalse);
    expect(fixture.store.requestedSaves, hasLength(1), reason: 'no retry');

    edit('two');
    await pumpEventQueue();
    expect(saver.state, isA<Saved>());
    expect(declared(), {0}, reason: 'the stopped edit did not ride along');
    expect(fixture.onDisk, contains('{two [%eval 0.30]}'));
  });

  test('a stopped save takes the document back to what the file holds, and '
      'the next edit lands on its own', () async {
    fixture.store.saves.add(
      const SaveRefused('game 3 would change but the edit was to game 1'),
    );
    session.setComment(NodePath.of([0, 1]), 'stopped words');
    await pumpEventQueue();
    expect(saver.state, isA<SaveStopped>());
    expect(session.commentAt(NodePath.of([0, 1])), 'Closed');

    edit('honest');
    await pumpEventQueue();
    expect(saver.state, isA<Saved>());
    expect(declared(), {0});
    expect(fixture.onDisk, isNot(contains('stopped words')));
    expect(fixture.onDisk, contains('{honest [%eval 0.30]}'));
  });

  test(
    'a copy after a stopped save writes the words the store refused',
    () async {
      fixture.store.saves.add(
        const SaveRefused('game 3 would change but the edit was to game 1'),
      );
      edit('refused words');
      await pumpEventQueue();
      expect(saver.state, isA<SaveStopped>());
      expect(await session.saveCopy('Elsewhere'), isA<CopySaved>());
      final copy = fixture.store.documents.entries.firstWhere(
        (entry) => entry.key.path.endsWith('Elsewhere.pgn'),
      );
      expect((copy.value as Opened).text, contains('refused words'));
    },
  );

  test('a copy can still be written after a save was stopped', () async {
    fixture.store.saves.add(const SaveRefused('game 3 would change'));
    edit('one');
    await pumpEventQueue();
    expect(saver.state, isA<SaveStopped>());
    expect(await session.saveCopy('Main draft'), isA<CopySaved>());
    expect(
      fixture.store.documents.keys.map((ref) => ref.path),
      contains(endsWith('Main draft.pgn')),
    );
  });

  test(
    'a copy the store could not read back is not a copy that was made',
    () async {
      fixture.store.creates.add(
        const WriteUnverified('the file could not be read back after writing'),
      );
      final result = await session.saveCopy('Main draft');
      expect((result as CopyFailed).detail, contains('could not be read back'));
    },
  );

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

  test('a store that throws is a failed save, not a wedged saver', () async {
    fixture.store.throwOnSave = StateError('the lock database fell over');
    edit('one');
    await pumpEventQueue();
    expect((saver.state as SaveFailed).detail, contains('the lock database'));
    expect(saver.settled, isFalse, reason: 'the words are in no file');
    // The saver is not stuck on a write that never answered, and flushing
    // does not hand the exception out again.
    await saver.flush();
    edit('two');
    await pumpEventQueue();
    expect(saver.state, isA<Saved>());
    expect(saver.settled, isTrue);
    expect(fixture.onDisk, contains('{two [%eval 0.30]}'));
  });

  test('a save that failed keeps the words for the next try', () async {
    fixture.store.saves.add(const IoFailure('No space left on device'));
    edit('one');
    await pumpEventQueue();
    expect(saver.settled, isFalse);
    expect(
      fixture.store.requestedSaves,
      hasLength(1),
      reason: 'a failure is not retried on its own',
    );
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
