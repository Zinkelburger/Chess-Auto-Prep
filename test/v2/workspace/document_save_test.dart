import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    show Collision, IoFailure, Opened;
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

  test('a save landing after another chapter is open is discarded', () async {
    final other = chapterRef('KID', 'Other');
    fixture.store.documents[other] = Opened(
      whiteChapter,
      scriptedRevision(whiteChapter),
    );
    fixture.store.hold = true;
    edit('one');
    final opening = session.open(other);
    fixture.store.releaseLast(); // the open answers first
    await pumpEventQueue();
    expect(await opening, isA<DocumentOpened>());
    fixture.store.releaseAll(); // the save for the old chapter lands now
    await pumpEventQueue();
    expect(saver.canUndo, isFalse, reason: 'its receipt belongs to nothing');
    expect(saver.state, isA<Saved>());
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
      fixture.store.releaseAll();
      await opening;
      expect(await copying, isA<CopyNameTaken>());
    });
  });
}
