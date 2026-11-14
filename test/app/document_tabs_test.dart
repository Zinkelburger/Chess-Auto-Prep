import 'package:chess_auto_prep/app/document_tabs.dart';
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart' as store;
import 'package:chess_auto_prep/storage/saved_place.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  test(
    'analysis retains the full game and source cursor without saving',
    () async {
      await w.requests.open(kidMain);
      final original = w.session.chapter!;
      w.session.cursor.forward();
      final cursor = w.session.cursor.value;
      await w.requests.newAnalysisBoard();
      final analysis = w.requests.documents.tabs.selected;
      expect(w.session.cursor.value, cursor);
      expect(
        w.session.tree!.children.single.children.length,
        original.tree.children.single.children.length,
      );
      w.session.cursor.toEnd();
      final end = w.session.cursor.value;
      w.session.setComment(end, 'Only in analysis');
      await w.requests.documents.select(kidMain);
      expect(w.session.source, kidMain);
      expect(w.session.cursor.value, cursor);
      expect(w.session.commentAt(end), isNot('Only in analysis'));
      await w.requests.documents.select(analysis);
      expect(w.session.cursor.value, end);
      expect(w.session.commentAt(end), 'Only in analysis');
      expect(w.session.canUndo, isTrue);
      await w.session.undo();
      expect(w.session.commentAt(end), isNot('Only in analysis'));
      expect(w.store.requestedSaves, isEmpty);
    },
  );

  test(
    'multiple analysis tabs retain separate moves and close to a neighbour',
    () async {
      w.session.playMove('e2e4');
      final first = w.requests.documents.tabs.selected;
      await w.requests.newAnalysisBoard();
      final second = w.requests.documents.tabs.selected;
      w.session.playMove('c7c5');
      await w.requests.documents.select(first);
      expect(w.session.cursor.currentMove?.san, 'e4');
      w.session.playMove('e7e5');
      await w.requests.documents.select(second);
      expect(w.session.cursor.currentMove?.san, 'c5');
      await w.requests.documents.close(second);
      expect(w.session.cursor.currentMove?.san, 'e5');
      expect(w.requests.documents.tabs.open, [first]);
      await w.requests.documents.close(first);
      expect(w.session.cursor.value, const NodePath.root());
      expect(w.session.tree!.children, isEmpty);
      expect(w.requests.documents.tabs.open.length, 1);
    },
  );

  test('moves played on the starting board while the last file is read '
      'keep its tab open', () async {
    final blank = w.requests.documents.tabs.selected;
    w.store.hold = true;
    final resumed = w.requests.resume(
      SavedPlace(mode: Mode.repertoires.name, path: kidMain.path),
    );
    await pumpEventQueue();
    w.session.playMove('e2e4');
    w.store.hold = false;
    w.store.releaseAll();
    await resumed;
    expect(w.session.source, kidMain);
    expect(w.requests.documents.tabs.open, contains(blank));
    await w.requests.documents.select(blank);
    expect(w.session.cursor.currentMove?.san, 'e4');
  });

  test('a file tab gone back to shows the games it read, without reading '
      'them again; a file changed since is read', () async {
    await w.requests.open(kidMain);
    final games = w.session.chapter!.lines;
    await w.requests.newAnalysisBoard();
    final analysis = w.requests.documents.tabs.selected;
    await w.requests.documents.select(kidMain);
    expect(w.session.source, kidMain);
    expect(w.session.chapter!.lines, same(games));

    await w.requests.documents.select(analysis);
    const changed =
        '// Color: White\n\n[Event "Changed elsewhere"]\n\n1. g3 *\n';
    w.store.documents[kidMain] = store.Opened(
      changed,
      scriptedRevision(changed),
    );
    await w.requests.documents.select(kidMain);
    expect(w.session.chapter!.lines, isNot(same(games)));
    expect(w.session.tree!.children.single.san, 'g3');
  });

  test('a file tab gone back to keeps the undo of edits it already wrote; '
      'a file changed since takes none', () async {
    await w.requests.open(kidMain);
    w.session.setComment(const NodePath.root(), 'Saved note');
    await w.saver.flush();
    expect(w.saver.settled, isTrue);
    final written = (w.store.documents[kidMain] as store.Opened).text;
    expect(written, contains('Saved note'));

    await w.requests.open(benkoMain);
    await w.requests.documents.select(kidMain);
    expect(w.session.canUndo, isTrue);
    await w.session.undo();
    expect(
      (w.store.documents[kidMain] as store.Opened).text,
      isNot(contains('Saved note')),
    );
    expect(w.session.commentAt(const NodePath.root()), isNot('Saved note'));

    // Written again, then changed outside while another tab is up: the
    // reading of the file wins and nothing of the old history comes back.
    w.session.setComment(const NodePath.root(), 'Saved note');
    await w.saver.flush();
    await w.requests.newAnalysisBoard();
    const changed =
        '// Color: White\n\n[Event "Changed elsewhere"]\n\n1. g3 *\n';
    w.store.documents[kidMain] = store.Opened(
      changed,
      scriptedRevision(changed),
    );
    await w.requests.documents.select(kidMain);
    expect(w.session.tree!.children.single.san, 'g3');
    expect(w.session.canUndo, isFalse);
  });

  test('undo kept by a file tab survives visiting an analysis board and '
      'is not given to another file', () async {
    await w.requests.open(kidMain);
    w.session.setComment(const NodePath.root(), 'Saved note');
    await w.saver.flush();
    await w.requests.newAnalysisBoard();
    await w.requests.open(benkoMain);
    expect(w.session.canUndo, isFalse);
    await w.requests.documents.select(kidMain);
    expect(w.session.canUndo, isTrue);
  });

  test('a parked viewer draft comes back over the saves it was made on, '
      'with their undo', () async {
    await w.requests.open(kidMain);
    w.session.setComment(const NodePath.root(), 'Saved note');
    await w.saver.flush();
    w.session.holdsEdits = true;
    w.session.cursor.forward();
    final cursor = w.session.cursor.value;
    w.session.setComment(cursor, 'Held note');
    await w.requests.newAnalysisBoard();
    await w.requests.documents.select(kidMain);
    expect(w.session.hasHeldEdits, isTrue);
    w.session.discardHeld();
    expect(w.session.commentAt(cursor), isNot(contains('Held note')));
    expect(w.session.canUndo, isTrue);
    await w.session.undo();
    expect(
      (w.store.documents[kidMain] as store.Opened).text,
      isNot(contains('Saved note')),
    );
  });

  test('file tabs show and restore the mode they were opened in', () async {
    await w.requests.open(kidMain);
    expect(w.requests.documents.tabs.tabOf(kidMain).title, 'Builder · Main');
    w.requests.switchTo(Mode.pgnViewer);
    await pumpEventQueue();
    expect(w.requests.documents.tabs.tabOf(kidMain).title, 'Builder · Main');
    await w.requests.open(benkoMain);
    expect(w.requests.documents.tabs.tabOf(benkoMain).title, 'Viewer · Main');
    w.requests.switchTo(Mode.repertoires);
    await pumpEventQueue();
    expect(w.session.source, kidMain);
    await w.requests.documents.select(benkoMain);
    expect(w.requests.mode, Mode.pgnViewer);
    expect(w.requests.documents.tabs.tabOf(benkoMain).title, 'Viewer · Main');
  });

  test('a viewer draft survives visiting an analysis tab', () async {
    w.requests.switchTo(Mode.pgnViewer);
    await w.requests.open(kidMain);
    w.session.holdsEdits = true;
    w.session.cursor.forward();
    final cursor = w.session.cursor.value;
    w.session.setComment(cursor, 'Unsaved viewer note');
    expect(w.session.hasHeldEdits, isTrue);
    await w.requests.newAnalysisBoard();
    await w.requests.documents.select(kidMain);
    expect(w.session.hasHeldEdits, isTrue);
    expect(w.session.cursor.value, cursor);
    expect(w.session.commentAt(cursor), contains('Unsaved viewer note'));
    expect(w.store.requestedSaves, isEmpty);
    w.session.discardHeld();
    expect(w.session.commentAt(cursor), isNot(contains('Unsaved viewer note')));
  });

  test('a parked draft put away, by keeping or discarding it, does not come '
      'back with its tab', () async {
    for (final keep in [false, true]) {
      final w = WindowFixture();
      addTearDown(w.dispose);
      w.requests.switchTo(Mode.pgnViewer);
      await w.requests.open(kidMain);
      w.session.holdsEdits = true;
      w.session.setComment(const NodePath.root(), 'Parked note');
      await w.requests.newAnalysisBoard();
      await w.requests.documents.select(kidMain);
      expect(w.session.hasHeldEdits, isTrue);
      if (keep) {
        w.session.keepHeld();
      } else {
        w.session.discardHeld();
      }
      await w.requests.newAnalysisBoard();
      await w.requests.documents.select(kidMain);
      expect(w.session.hasHeldEdits, isFalse, reason: 'keep: $keep');
    }
  });

  test('a mode with no tab of its own gets an empty board, not an analysis '
      'with a game on it', () async {
    await w.requests.open(kidMain);
    await w.requests.newAnalysisBoard();
    expect(w.session.isScratch, isTrue);
    expect(w.session.canUndo, isFalse);
    expect(w.session.tree!.children, isNotEmpty);
    w.requests.switchTo(Mode.tactics);
    await pumpEventQueue();
    expect(w.session.tree!.children, isEmpty);
  });
  test('selecting the active tab cancels a pending switch', () async {
    await w.requests.open(kidMain);
    await w.requests.open(benkoMain);
    w.store.hold = true;
    final pending = w.requests.documents.select(kidMain);
    await pumpEventQueue();
    await w.requests.documents.select(benkoMain);
    w.store.releaseAll();
    await pending;
    expect(w.session.source, benkoMain);
    expect(w.requests.documents.tabs.selected, benkoMain);
  });
  test(
    'switching PGN tabs restores the game list as well as the board',
    () async {
      final first = collectionRef('First');
      final second = collectionRef('Second');
      w.store.documents[first] = store.Opened(
        threeGameFile,
        scriptedRevision(threeGameFile),
      );
      w.store.documents[second] = store.Opened(
        threeGameFile,
        scriptedRevision(threeGameFile),
      );
      await w.requests.openFile(first, game: 1);
      w.session.cursor.forward();
      final cursor = w.session.cursor.value;
      await w.requests.openFile(second, game: 2);
      await w.requests.documents.select(first);
      expect(w.viewer.file, first);
      expect(w.viewer.current, 1);
      expect(w.session.cursor.value, cursor);
      await w.requests.documents.select(second);
      expect(w.viewer.file, second);
      expect(w.viewer.current, 2);
    },
  );

  test('opening another game of the file holding viewer edits keeps them, '
      'in the session and in its tab', () async {
    final games = collectionRef('Games');
    w.store.documents[games] = store.Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await w.requests.openFile(games, game: 1);
    w.session.holdsEdits = true;
    w.session.setComment(NodePath.of(const [0]), 'Held viewer note');
    expect(w.session.hasHeldEdits, isTrue);
    await w.requests.openFile(games, game: 2);
    expect(w.session.game, 2);
    expect(w.session.hasHeldEdits, isTrue);
    // The tab parks the edits and brings them back.
    await w.requests.newAnalysisBoard();
    await w.requests.documents.select(games);
    expect(w.session.hasHeldEdits, isTrue);
    w.session.showGame(1);
    expect(w.session.commentAt(NodePath.of(const [0])), 'Held viewer note');
    expect(w.store.requestedSaves, isEmpty);
  });

  test(
    'a parked viewer draft retains its original save precondition',
    () async {
      await w.requests.open(kidMain);
      w.session.holdsEdits = true;
      w.session.setComment(const NodePath.root(), 'My draft');
      await w.requests.newAnalysisBoard();
      final before = (w.store.documents[kidMain] as store.Opened).text;
      final changed = before.replaceFirst(
        '[Event ',
        '[Site "Updated elsewhere"]\n[Event ',
      );
      w.store.documents[kidMain] = store.Opened(
        changed,
        scriptedRevision(changed),
      );
      await w.requests.documents.select(kidMain);
      w.session.keepHeld();
      await w.saver.flush();
      expect((w.store.documents[kidMain] as store.Opened).text, changed);
      expect(w.saver.settled, isFalse);
    },
  );

  test('analysis tabs are numbered from the second', () async {
    // A blank board is reused; one with a move on it is not.
    w.session.playMove('e2e4');
    await w.requests.newAnalysisBoard();
    final titles = [
      for (final tab in w.requests.documents.tabs.tabs) tab.title,
    ];
    expect(titles, hasLength(2));
    expect(titles.first, endsWith(' · Analysis'));
    expect(titles.last, endsWith(' · Analysis 2'));
  });

  test('a tab comes back the way round its board was', () async {
    await w.requests.open(kidMain);
    final side = w.session.orientation;
    await w.requests.newAnalysisBoard();
    w.session.flip();
    await w.requests.documents.select(kidMain);
    expect(w.session.orientation, side);
  });

  test('a document handed to another mode is retitled for it', () async {
    await w.requests.open(kidMain);
    w.requests.documents.carry(Mode.trainer);
    expect(w.requests.documents.tabs.tabOf(kidMain).title, 'Trainer · Main');
  });

  test('taken down, it hands nothing on', () async {
    await w.requests.open(kidMain);
    final tabs = DocumentTabs(session: w.session, requests: w.requests)
      ..dispose();
    tabs.carry(Mode.trainer);
  });
}
