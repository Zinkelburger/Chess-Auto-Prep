// The workspace's commands over whole lines: renaming one, taking one out,
// deciding which branch is the main line, and which side the chapter is for.
// Each of them has to reach the disk, and each has to leave the games it did
// not name exactly as they were.
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/workspace/chapter_commands.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

/// Three lines from the initial position, the second branching at move 1.
const threeLines = '''
// Book
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 2. c4 e6 *

[Event "Indian"]
[Result "*"]

1. d4 Nf6 *

[Event "Slav"]
[Result "*"]

1. d4 d5 2. c4 c6 *
''';

void main() {
  test('renaming a line puts the new name on disk', () async {
    final fixture = await openSession(threeLines);
    addTearDown(fixture.dispose);

    renameLine(fixture.session, 1, 'King’s Indian');
    await pumpEventQueue();

    expect(fixture.onDisk, contains('[Event "King’s Indian"]'));
    expect(fixture.onDisk, contains('[Event "Queen\'s"]'));
    expect(fixture.saver.state, isA<Saved>());
  });

  test(
    'deleting a line takes it off the disk and undo brings it back',
    () async {
      final fixture = await openSession(threeLines);
      addTearDown(fixture.dispose);

      deleteLine(fixture.session, 1);
      await pumpEventQueue();
      expect(fixture.onDisk, isNot(contains('[Event "Indian"]')));
      expect(fixture.session.chapter!.lines, hasLength(2));

      await fixture.session.undo();

      expect(fixture.onDisk, threeLines);
      expect(fixture.session.chapter!.lines, hasLength(3));
    },
  );

  test('a deletion says which games of the file it left', () async {
    final fixture = await openSession(threeLines);
    addTearDown(fixture.dispose);

    deleteLine(fixture.session, 1);
    await pumpEventQueue();

    final scope = fixture.store.requestedSaves.single.scope;
    expect((scope as GamesRearranged).arranged.order, [0, 2]);
  });

  test('making a branch the main line reorders the file', () async {
    final fixture = await openSession(threeLines);
    addTearDown(fixture.dispose);
    final tree = fixture.session.tree!;
    final indian = pathOfSans(tree, ['d4', 'Nf6'])!;

    makeMainLine(fixture.session, indian);
    await pumpEventQueue();

    expect(
      fixture.onDisk.indexOf('[Event "Indian"]'),
      lessThan(fixture.onDisk.indexOf('[Event "Queen\'s"]')),
    );
    expect(fixture.session.tree!.children.first.children.first.san, 'Nf6');
  });

  test('the cursor follows its own moves through a reorder', () async {
    final fixture = await openSession(threeLines);
    addTearDown(fixture.dispose);
    final tree = fixture.session.tree!;
    fixture.session.goTo(pathOfSans(tree, ['d4', 'd5', 'c4', 'c6'])!);

    makeMainLine(fixture.session, pathOfSans(tree, ['d4', 'Nf6'])!);
    await pumpEventQueue();

    expect(fixture.session.currentMove!.san, 'c6');
  });

  test('deleting from a move takes the moves under it off the disk', () async {
    final fixture = await openSession(threeLines);
    addTearDown(fixture.dispose);
    final tree = fixture.session.tree!;

    deleteFrom(fixture.session, pathOfSans(tree, ['d4', 'd5', 'c4'])!);
    await pumpEventQueue();

    expect(fixture.onDisk, isNot(contains('c4')));
    expect(fixture.onDisk, contains('[Event "Slav"]'));
    expect(fixture.session.cursor, const NodePath.root());
  });

  test('changing the side writes the Color line and turns the board', () async {
    final fixture = await openSession(threeLines);
    addTearDown(fixture.dispose);

    setSide(fixture.session, Side.black);
    await pumpEventQueue();

    expect(fixture.onDisk, startsWith('// Book\n// Color: Black\n'));
    expect(fixture.onDisk, contains('1. d4 d5 2. c4 e6 *'));
    expect(fixture.session.orientation, Side.black);
  });

  test(
    'an edit a line will not take is refused and nothing is written',
    () async {
      final fixture = await openSession(brokenSecondGame);
      addTearDown(fixture.dispose);
      final tree = fixture.session.tree!;

      deleteFrom(fixture.session, pathOfSans(tree, ['e4', 'e5'])!);
      await pumpEventQueue();

      expect(fixture.session.refusedEdit, isA<EditNotWritten>());
      expect(fixture.onDisk, brokenSecondGame);
      expect(fixture.store.requestedSaves, isEmpty);
    },
  );

  test('a document that opened to read refuses every one of them', () async {
    final fixture = await openSession(
      threeLines,
      readOnly: 'the file is not in an encoding this app writes',
    );
    addTearDown(fixture.dispose);

    deleteLine(fixture.session, 0);
    setSide(fixture.session, Side.black);
    await pumpEventQueue();

    expect(fixture.session.refusedEdit, isA<NotEditable>());
    expect(fixture.onDisk, threeLines);
    expect(fixture.store.requestedSaves, isEmpty);
  });

  test('the chapter the app already ships with survives a rename', () async {
    final fixture = await openSession(whiteChapter);
    addTearDown(fixture.dispose);

    renameLine(fixture.session, 2, 'Sidelines');
    await pumpEventQueue();

    expect(fixture.onDisk, contains('[Event "Sidelines"]'));
    expect(fixture.onDisk, contains('[LineID "line_MS4gZDQgZDUgMi4gYzYy"]'));
    expect(fixture.onDisk, contains('{Our repertoire against 1... d5.}'));
  });
}

/// Two games, the second holding a word no reader can take.
const brokenSecondGame = '''
// Hurt
// Color: White

[Event "Fine"]
[Result "*"]

1. e4 e5 2. Nf3 *

[Event "Broken"]
[Result "*"]

1. e4 e5 2. Qq9 *
''';
