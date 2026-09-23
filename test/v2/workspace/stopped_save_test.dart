import 'package:chess_auto_prep/v2/workspace/copy_aside.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    show Opened, SaveRefused;
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/save_state.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

/// A save the store stopped freezes the document: nothing is written
/// again, nothing is taken away, and the user chooses what happens to
/// the words on screen.
///
/// The text of the copy written as [name].
String _copyText(SessionFixture fixture, String name) {
  final copy = fixture.store.documents.entries.firstWhere(
    (entry) => entry.key.path.endsWith(name),
  );
  return (copy.value as Opened).text;
}

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

  test('a save the store stopped writes nothing more at all', () async {
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
    expect(saver.state, isA<SaveStopped>());
    expect(fixture.store.requestedSaves, hasLength(1), reason: 'still frozen');
    expect(session.commentAt(sicilian), contains('two'));
    expect(fixture.onDisk, isNot(contains('two')));
  });

  test(
    'an undo while a save is stopped says why, and takes nothing back',
    () async {
      edit('first');
      await pumpEventQueue();
      fixture.store.saves.add(
        const SaveRefused('game 3 would change but the edit was to game 1'),
      );
      edit('second');
      await pumpEventQueue();
      expect(saver.state, isA<SaveStopped>());
      fixture.store.requestedSaves.clear();

      final undone = await saver.undo();
      expect((undone as UndoRefused).reason, contains('Save a copy or reload'));
      expect(fixture.store.requestedSaves, isEmpty);
    },
  );

  test(
    'a stopped save keeps every word on screen, the one behind it too',
    () async {
      fixture.store.hold = true;
      edit('first');
      await pumpEventQueue(); // the write goes out and is held
      session.setComment(NodePath.of([0, 1]), 'second'); // waits behind it
      fixture.store.saves.add(
        const SaveRefused('game 3 would change but the edit was to game 1'),
      );
      fixture.store.releaseAll();
      await pumpEventQueue();
      fixture.store.hold = false;

      expect(saver.state, isA<SaveStopped>());
      expect(session.commentAt(sicilian), contains('first'));
      expect(session.commentAt(NodePath.of([0, 1])), 'second');
      expect(fixture.onDisk, isNot(contains('first')));
      expect(fixture.onDisk, isNot(contains('second')));

      expect(await saveCopy(session, saver, 'Elsewhere'), isA<CopySaved>());
      expect(_copyText(fixture, 'Elsewhere.pgn'), contains('first'));
      expect(_copyText(fixture, 'Elsewhere.pgn'), contains('second'));
    },
  );

  test('reloading after a stopped save takes what is on disk', () async {
    fixture.store.saves.add(
      const SaveRefused('game 3 would change but the edit was to game 1'),
    );
    edit('stopped words');
    await pumpEventQueue();
    expect(saver.state, isA<SaveStopped>());

    expect(await session.reloadFromDisk(), isA<DocumentOpened>());
    await pumpEventQueue();
    expect(saver.state, isA<Saved>());
    expect(session.commentAt(sicilian), isNot(contains('stopped words')));
    expect(writeChapter(session.chapter!), fixture.onDisk);
  });

  test('reloading after an undo takes the version the undo put back', () async {
    edit('first');
    await pumpEventQueue();
    expect(await saver.undo(), isA<Restored>());
    await pumpEventQueue();

    expect(await session.reloadFromDisk(), isA<DocumentOpened>());
    expect(session.commentAt(sicilian), isNot(contains('first')));
    expect(writeChapter(session.chapter!), fixture.onDisk);
  });
  test(
    'a hold for a rename writes nothing while the document is frozen',
    () async {
      fixture.store.hold = true;
      edit('first');
      await pumpEventQueue(); // the write goes out and is held
      session.setComment(NodePath.of([0, 1]), 'second'); // waits behind it
      fixture.store.saves.add(
        const SaveRefused('game 3 would change but the edit was to game 1'),
      );
      fixture.store.releaseAll();
      await pumpEventQueue();
      fixture.store.hold = false;
      expect(saver.state, isA<SaveStopped>());
      fixture.store.requestedSaves.clear();

      // What a rename does: hold the file still, then let the saver go again.
      await saver.holdStill((revision) async => revision);
      await pumpEventQueue();

      expect(fixture.store.requestedSaves, isEmpty, reason: 'still frozen');
      expect(saver.state, isA<SaveStopped>());
      expect(session.commentAt(sicilian), contains('first'));
      expect(session.commentAt(NodePath.of([0, 1])), 'second');
    },
  );

  test('a copy made on the way out leaves the session where it is', () async {
    fixture.store.saves.add(
      const SaveRefused('game 3 would change but the edit was to game 1'),
    );
    edit('frozen words');
    await pumpEventQueue();

    final copy = await copyAside(session, saver, 'Elsewhere') as CopySaved;
    expect(copy.nowEditing, isFalse);
    expect(session.source, fixture.ref, reason: 'still on the original');
    expect(saver.state, isA<SaveStopped>());
    expect(_copyText(fixture, 'Elsewhere.pgn'), contains('frozen words'));
  });

  test('a copy of a frozen document becomes the document', () async {
    fixture.store.saves.add(
      const SaveRefused('game 3 would change but the edit was to game 1'),
    );
    edit('frozen words');
    await pumpEventQueue();
    expect(saver.state, isA<SaveStopped>());

    final copy = await saveCopy(session, saver, 'Elsewhere') as CopySaved;
    expect(copy.nowEditing, isTrue);
    expect(session.source?.name, 'Elsewhere');
    expect(saver.state, isA<Saved>());
    expect(session.commentAt(sicilian), contains('frozen words'));

    // And it takes words again, into the copy.
    fixture.store.requestedSaves.clear();
    edit('more words');
    await pumpEventQueue();
    expect(saver.state, isA<Saved>());
    expect(fixture.store.requestedSaves, hasLength(1));
    expect(_copyText(fixture, 'Elsewhere.pgn'), contains('more words'));
  });
}
