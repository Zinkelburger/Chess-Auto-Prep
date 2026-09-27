import 'dart:convert';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart'
    show readOffThreadFrom;
import 'package:chess_auto_prep/v2/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/study_edits.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    show Conflict, Opened, RestoreRefused;
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/big_chapter.dart';
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

  group('the cursor after an undo', () {
    /// Opens [_listedEarlyThenLate] with the cursor at [at], edits it once
    /// over a file that held [_listedLateThenEarly], then takes the edit
    /// back.
    Future<DocumentSession> undoneAt(NodePath at) async {
      final local = await openSession(_listedEarlyThenLate);
      addTearDown(local.dispose);
      local.session.goTo(at);
      local.store.hold = true;
      local.session.setComment(const NodePath.root(), 'a note');
      await pumpEventQueue(); // the write goes out and is held
      // The store's receipt says what the file held when the save replaced
      // it, and an undo puts exactly that back.
      local.store.documents[local.ref] = Opened(
        _listedLateThenEarly,
        scriptedRevision(_listedEarlyThenLate),
      );
      local.store.releaseAll();
      await pumpEventQueue();
      local.store.hold = false;
      await local.session.undo();
      return local.session;
    }

    test('stays on the move it was on, wherever the file lists it', () async {
      final restored = await undoneAt(NodePath.of([1]));
      expect(restored.currentMove?.san, 'd4');
      expect(restored.cursor, NodePath.of([0]));
    });

    test('falls back to the deepest move the file still has', () async {
      final restored = await undoneAt(NodePath.of([0, 0]));
      expect(restored.currentMove?.san, 'e4');
      expect(restored.cursor, NodePath.of([1]));
    });
  });

  test(
    'an undo of a version the store never kept leaves the file alone',
    () async {
      session.setComment(NodePath.of([0]), 'mine');
      await pumpEventQueue();
      final before = fixture.onDisk;
      fixture.store.saves.add(
        const RestoreRefused('these are not the bytes of any kept version'),
      );

      final result = await session.undo() as UndoRefused;
      expect(result.reason, contains('not among the ones kept'));
      // The file was not touched, so nothing about the document is unsaved.
      expect(saver.state, isA<Saved>());
      expect(saver.settled, isTrue);
      expect(fixture.onDisk, before);
      expect(saver.canUndo, isTrue, reason: 'the history is still there');
    },
  );

  test('nothing to undo is not an error', () async {
    await session.undo();
    expect(saver.state, isA<Saved>());
  });

  test('words typed during an undo win, and the undo waits', () async {
    edit('B');
    await pumpEventQueue();
    fixture.store.hold = true;
    final undoing = session.undo();
    await pumpEventQueue();
    edit('C'); // typed while the undo is still being written
    var landed = false;
    final flushed = saver.flush().then((_) => landed = true);
    await pumpEventQueue();
    expect(landed, isFalse, reason: 'the undo is still going out');
    fixture.store.releaseAll(); // the undo's write
    await pumpEventQueue();
    expect(landed, isFalse, reason: 'the newer words are still on their way');
    expect(saver.state, isNot(isA<Saved>()));
    fixture.store.releaseAll(); // the words behind it
    await flushed;
    expect(await undoing, isA<UndoRefused>(), reason: 'the newer words won');
    // The file, the screen and the header say the same thing.
    expect(saver.state, isA<Saved>());
    expect(fixture.onDisk, contains('{C [%eval 0.30]}'));
    expect(session.commentAt(sicilian), 'C [%eval 0.30]');
    // And the press that was refused is the next step back, not a step to
    // where the file already is.
    fixture.store.hold = false;
    await session.undo();
    expect(session.commentAt(sicilian), 'The Sicilian [%eval 0.30]');
    expect(fixture.onDisk, contains('{The Sicilian [%eval 0.30]}'));
  });

  test('words typed during an undo of an edit to another line say they '
      'change that line too', () async {
    session.setComment(NodePath.of([0, 1]), 'the closed line'); // line 2
    await pumpEventQueue();
    fixture.store.hold = true;
    final undoing = session.undo();
    await pumpEventQueue();
    session.setComment(NodePath.of([0, 0]), 'typed meanwhile'); // line 1
    fixture.store.releaseAll(); // the undo's write
    await pumpEventQueue();
    fixture.store.releaseAll(); // the words behind it
    expect(await undoing, isA<UndoRefused>(), reason: 'the newer words won');

    // They were typed over the version the undo took away, so against the
    // version it put back they change both lines, and the save says so.
    final save = fixture.store.requestedSaves.last;
    expect(
      changeOutsideScope(
        previous: utf8.encode(blackChapter),
        next: utf8.encode(save.text),
        scope: save.scope,
      ),
      isNull,
    );
    expect(fixture.onDisk, contains('{the closed line}'));
    expect(fixture.onDisk, contains('{typed meanwhile}'));
  });

  test('an edit made while an undo reads a large chapter back is refused, '
      'and the undo shows what it put back', () async {
    // Large enough to be read on another isolate, which is what leaves
    // time to edit between the file going back and the screen following.
    final book = bigChapter(games: 700);
    expect(book.length, greaterThan(readOffThreadFrom));
    final local = await openSession(book, name: 'Book');
    addTearDown(local.dispose);
    final first = NodePath.of([0]);
    local.session.setComment(first, 'B');
    await pumpEventQueue();

    final undoing = local.session.undo();
    await Future<void>.delayed(Duration.zero);
    expect(local.saver.state, isA<Saved>(), reason: 'the file is back');
    expect(local.session.commentAt(first), 'B', reason: 'and still being read');
    local.session.setComment(first, 'typed while it was read');
    expect(local.session.refusedEdit, isA<EditNotWritten>());

    expect(await undoing, isA<Restored>());
    await pumpEventQueue();
    expect(local.session.commentAt(first), isNull);
    expect(local.session.refusedEdit, isNull);
    expect(local.onDisk, book);
    expect(
      local.store.requestedSaves,
      hasLength(2),
      reason: 'the edit and the undo; nothing was written over the undo',
    );
  });

  group('an undo of an edit that moved the board', () {
    test('shows a renamed chapter under its old name again', () async {
      const path = '/repertoires/Course/Course.pgn';
      final alapin = ChapterRef.at(path, section: 'Sicilian');
      final store = ScriptedDocumentStore()
        ..documents[ChapterRef.at(path)] = Opened(
          _course,
          scriptedRevision(_course),
        );
      final saver = DocumentSaver(store, delay: Duration.zero);
      final local = DocumentSession(store, saver);
      addTearDown(() {
        local.dispose();
        saver.dispose();
      });
      await local.open(alapin);
      expect(
        local.applyToFile(
          (file) => sectionRenamed(file, 'Sicilian', 'Anti'),
          section: 'Anti',
        ),
        isNull,
      );
      await pumpEventQueue();
      expect(local.source, ChapterRef.at(path, section: 'Anti'));

      expect(await local.undo(), isA<Restored>());

      expect(local.source, alapin);
      expect(local.chapter!.name, 'Sicilian');
      expect(local.chapter!.lines, hasLength(1));
      // What is played now goes into the chapter's own game, and no game is
      // written under the name the undo took away.
      local.toEnd();
      local.playMove('d7d5');
      await pumpEventQueue();
      final text = (store.documents[ChapterRef.at(path)]! as Opened).text;
      expect(text, contains('1. e4 c5 2. c3 d5 *'));
      expect(text, isNot(contains('Anti')));
    });

    test('leaves a study on its last chapter when the one it showed was the '
        'one taken back', () async {
      final local = await openSession(_study, name: 'Openings');
      addTearDown(local.dispose);
      await local.session.open(local.ref, game: 1);
      expect(
        local.session.apply(
          (c) => addChapter(
            c,
            study: 'Openings',
            name: 'Delta',
            orientation: Side.white,
          ),
        ),
        isNull,
      );
      await pumpEventQueue();
      expect(local.session.game, 3);

      expect(await local.session.undo(), isA<Restored>());

      expect(local.session.gameCount, 3);
      expect(local.session.game, 2);
      expect(local.session.tree!.children.single.san, 'c4');
      local.session.toEnd();
      local.session.playMove('e7e5');
      await pumpEventQueue();
      expect(local.onDisk, contains('1. c4 e5 *'));
    });
  });
}

/// Three games of one file in two chapters named by tag.
const _course = '''
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

/// A study of three chapters, each one game.
const _study = '''
[Event "Openings: Alpha"]
[StudyName "Openings"]
[ChapterName "Alpha"]

1. e4 *

[Event "Openings: Beta"]
[StudyName "Openings"]
[ChapterName "Beta"]

1. d4 *

[Event "Openings: Gamma"]
[StudyName "Openings"]
[ChapterName "Gamma"]

1. c4 *
''';

/// A chapter where `e4` is the first move listed and `d4` the second.
const _listedEarlyThenLate = '''
// Color: White

[Event "One"]
[Result "*"]

1. e4 e5 *

[Event "Two"]
[Result "*"]

1. d4 *
''';

/// The same two moves the other way round, so every path into the tree of
/// [_listedEarlyThenLate] names another move here.
const _listedLateThenEarly = '''
// Color: White

[Event "One"]
[Result "*"]

1. d4 d5 *

[Event "Two"]
[Result "*"]

1. e4 *
''';
