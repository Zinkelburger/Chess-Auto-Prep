import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/app/mode.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';
import '../support/viewer_fixture.dart';
import '../support/scripted_store.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart' as store;

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  test(
    'analysis retains the full game and source cursor without saving',
    () async {
      await w.requests.open(kidMain);
      final original = w.session.chapter!;
      w.session.forward();
      final cursor = w.session.cursor;
      await w.requests.newAnalysisBoard();
      final analysis = w.requests.documents.tabs.selected;
      expect(w.session.cursor, cursor);
      expect(
        w.session.tree!.children.single.children.length,
        original.tree.children.single.children.length,
      );
      w.session.toEnd();
      final end = w.session.cursor;
      w.session.setComment(end, 'Only in analysis');
      await w.requests.documents.select(kidMain);
      expect(w.session.source, kidMain);
      expect(w.session.cursor, cursor);
      expect(w.session.commentAt(end), isNot('Only in analysis'));
      await w.requests.documents.select(analysis);
      expect(w.session.cursor, end);
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
      expect(w.session.currentMove?.san, 'e4');
      w.session.playMove('e7e5');
      await w.requests.documents.select(second);
      expect(w.session.currentMove?.san, 'c5');
      await w.requests.documents.close(second);
      expect(w.session.currentMove?.san, 'e5');
      expect(w.requests.documents.tabs.open, [first]);
      await w.requests.documents.close(first);
      expect(w.session.cursor, const NodePath.root());
      expect(w.session.tree!.children, isEmpty);
      expect(w.requests.documents.tabs.open.length, 1);
    },
  );

  test('file tabs show and restore their selected mode', () async {
    await w.requests.open(kidMain);
    expect(w.requests.documents.tabs.tabOf(kidMain).title, 'Builder · Main');
    w.requests.switchTo(Mode.pgnViewer);
    expect(w.requests.documents.tabs.tabOf(kidMain).title, 'Viewer · Main');
    await w.requests.open(benkoMain);
    w.requests.switchTo(Mode.repertoires);
    await w.requests.documents.select(kidMain);
    expect(w.requests.mode, Mode.pgnViewer);
    expect(w.requests.documents.tabs.tabOf(kidMain).title, 'Viewer · Main');
  });

  test('a viewer draft survives visiting an analysis tab', () async {
    w.requests.switchTo(Mode.pgnViewer);
    await w.requests.open(kidMain);
    w.session.holdsEdits = true;
    w.session.forward();
    final cursor = w.session.cursor;
    w.session.setComment(cursor, 'Unsaved viewer note');
    expect(w.session.hasHeldEdits, isTrue);
    await w.requests.newAnalysisBoard();
    await w.requests.documents.select(kidMain);
    expect(w.session.hasHeldEdits, isTrue);
    expect(w.session.commentAt(cursor), contains('Unsaved viewer note'));
    expect(w.store.requestedSaves, isEmpty);
    w.session.discardHeld();
    expect(w.session.commentAt(cursor), isNot(contains('Unsaved viewer note')));
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
      w.session.forward();
      final cursor = w.session.cursor;
      await w.requests.openFile(second, game: 2);
      await w.requests.documents.select(first);
      expect(w.viewer.file, first);
      expect(w.viewer.current, 1);
      expect(w.session.cursor, cursor);
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
}
