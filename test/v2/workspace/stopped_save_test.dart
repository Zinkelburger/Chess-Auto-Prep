import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    show Opened, SaveRefused;
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/save_state.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
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
      session.setComment(NodePath.of([0, 1]), 'second');
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

      expect(await session.saveCopy('Elsewhere'), isA<CopySaved>());
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

  test('an undo leaves the text the file now holds behind it', () async {
    edit('first');
    await pumpEventQueue();
    final undone = await saver.undo();
    expect(undone, isA<Restored>());
    expect(saver.committedText, isNot(contains('first')));
    expect(saver.committedText, fixture.onDisk);
  });
}
