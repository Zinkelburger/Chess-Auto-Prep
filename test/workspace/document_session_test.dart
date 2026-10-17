import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pv_text.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
import 'package:chess_auto_prep/workspace/session_results.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

void main() {
  late SessionFixture fixture;
  late DocumentSession session;
  var notifications = 0;

  Future<void> open(String text) async {
    fixture = await openSession(text);
    session = fixture.session;
    session.anyChange.addListener(() => notifications++);
    notifications = 0;
  }

  setUp(() => open(blackChapter));

  tearDown(() => fixture.dispose());

  test('opening a chapter shows its root from its side', () {
    expect(session.cursor.value.isRoot, isTrue);
    expect(session.cursor.fen.whiteToMove, isFalse);
    expect(session.orientation, Side.black);
    expect(session.cursor.currentMove, isNull);
    expect(session.source, fixture.ref);
  });

  test('forward and back walk the main line', () {
    session.cursor.forward();
    expect(session.cursor.currentMove?.san, 'c5');
    session.cursor.forward();
    expect(session.cursor.currentMove?.san, 'Nf3');
    session.cursor.back();
    expect(session.cursor.currentMove?.san, 'c5');
    session.cursor.back();
    expect(session.cursor.value.isRoot, isTrue);
    final before = notifications;
    session.cursor.back();
    expect(notifications, before, reason: 'backing off the root does nothing');
  });

  test('Enter steps into the variation at the cursor and Esc back out to '
      'where it branched', () {
    expect(session.cursor.enterVariation(), isFalse, reason: 'one first move');
    expect(
      session.cursor.leaveVariation(),
      isFalse,
      reason: 'on the main line',
    );
    session.cursor.goTo(
      NodePath.of([0, 0]),
    ); // 2. Nf3, with 2... d6 or 2... Nc6
    expect(session.cursor.enterVariation(), isTrue);
    expect(session.cursor.currentMove?.san, 'Nc6');
    session.cursor.forward();
    expect(session.cursor.currentMove?.san, 'd4');
    expect(session.cursor.leaveVariation(), isTrue);
    expect(session.cursor.value, NodePath.of([0, 0]));
    expect(session.cursor.leaveVariation(), isFalse);
  });

  test('goTo ignores paths outside the tree', () {
    session.cursor.goTo(NodePath.of([0, 1]));
    expect(session.cursor.currentMove?.san, 'Nc3');
    session.cursor.goTo(NodePath.of([9]));
    expect(session.cursor.currentMove?.san, 'Nc3');
  });

  test('toEnd follows the main line from the cursor; toStart returns', () {
    session.cursor.goTo(NodePath.of([0, 0, 1]));
    session.cursor.toEnd();
    expect(session.cursor.currentMove?.san, 'd4');
    expect(session.cursor.value, NodePath.of([0, 0, 1, 0]));
    session.cursor.toStart();
    expect(session.cursor.value.isRoot, isTrue);
  });

  test('a chapter that is gone or unreadable is a sentence', () async {
    final ref = chapterRef('KID', 'Gone');
    expect(
      (await session.open(ref) as OpenFailed).reason,
      'Gone is no longer on disk',
    );
    fixture.store.documents[ref] = const Unreadable('Input/output error');
    expect(
      (await session.open(ref) as OpenFailed).reason,
      'Could not read Gone: Input/output error',
    );
    expect(
      session.source,
      fixture.ref,
      reason: 'a failed read leaves the open chapter alone',
    );
  });

  test('a move already in the tree only moves the cursor', () async {
    session.playMove('c7c5');
    expect(session.cursor.currentMove?.san, 'c5');
    await pumpEventQueue();
    expect(fixture.store.requestedSaves, isEmpty);
  });

  test('a move at the end of a line extends that line', () async {
    session.cursor.goTo(
      NodePath.of([0, 0, 0, 0, 0]),
    ); // 1... c5 2. Nf3 d6 3. d4 cxd4
    session.playMove('f3d4');
    expect(session.cursor.currentMove?.san, 'Nxd4');
    expect(session.chapter?.gameCount, 2, reason: 'no new line was needed');
    await pumpEventQueue();
    expect(fixture.onDisk, contains('cxd4 4. Nxd4'));
  });

  test('a move at a branch point becomes a line of its own', () async {
    session.cursor.goTo(NodePath.of([0]));
    session.playMove('c2c3');
    expect(session.cursor.currentMove?.san, 'c3');
    expect(session.chapter?.gameCount, 3);
    await pumpEventQueue();
    expect(fixture.onDisk, contains('1... c5 2. c3'));
    expect(fixture.onDisk, contains('LineID'));
  });

  test('a comment line not in the file goes on the board and writes '
      'nothing', () async {
    final from = NodePath.of([0]); // 1... c5
    final line = pvMoves(session.tree!.fenAt(from), ['g1f3', 'e7e6', 'd2d4']);
    final tree = session.tree;
    session.cursor.showCommentLine(from, line, 1);
    expect(session.cursor.value, from);
    expect(session.cursor.boardFen, line[1].after);
    expect(session.cursor.boardLastMove, 'e7e6');
    expect(
      session.cursor.fen,
      session.tree!.fenAt(from),
      reason: 'the file stays',
    );
    session.playMove('d2d4');
    expect(identical(session.tree, tree), isTrue, reason: 'no board moves');

    session.cursor.forward();
    expect(session.cursor.boardFen, line[2].after);
    session.cursor.forward();
    expect(
      session.cursor.boardFen,
      line[2].after,
      reason: 'the line ends there',
    );
    session.cursor.back();
    session.cursor.back();
    session.cursor.back();
    expect(session.cursor.commentLine.value, isNull);
    expect(session.cursor.boardFen, session.cursor.fen);
    expect(session.cursor.value, from);
    await pumpEventQueue();
    expect(fixture.store.requestedSaves, isEmpty);
  });

  test('moving in the file puts the board back on it', () {
    final from = NodePath.of([0]);
    final line = pvMoves(session.tree!.fenAt(from), ['c2c3']);
    session.cursor.showCommentLine(from, line, 0);
    session.cursor.goTo(from);
    expect(
      session.cursor.commentLine.value,
      isNull,
      reason: 'the same move again',
    );
    session.cursor.showCommentLine(from, line, 0);
    session.cursor.goTo(NodePath.of([0, 0]));
    expect(session.cursor.commentLine.value, isNull);
    session.cursor.showCommentLine(from, line, 0);
    expect(
      session.cursor.value,
      from,
      reason: 'the line starts at its comment',
    );
    session.cursor.showCommentLine(from, line, 0);
    session.flip();
    expect(
      session.cursor.commentLine.value,
      isNull,
      reason: 'a change to the view',
    );
  });

  test('a comment line the file already plays moves the cursor there', () {
    final line = pvMoves(session.tree!.rootFen, ['c7c5', 'g1f3', 'b8c6']);
    session.cursor.showCommentLine(const NodePath.root(), line, 2);
    expect(session.cursor.commentLine.value, isNull);
    expect(session.cursor.currentMove?.san, 'Nc6');
  });

  test('an illegal move changes nothing at all', () async {
    session.playMove('a1a8');
    expect(session.cursor.value.isRoot, isTrue);
    expect(notifications, 0);
    await pumpEventQueue();
    expect(fixture.store.requestedSaves, isEmpty);
  });

  test('a comment replaces the words and keeps the machine tokens', () async {
    session.setComment(NodePath.of([0]), 'Our Sicilian');
    await pumpEventQueue();
    expect(fixture.onDisk, contains('{Our Sicilian [%eval 0.30]}'));
    expect(session.commentAt(NodePath.of([0])), 'Our Sicilian [%eval 0.30]');
  });

  test('clearing a comment keeps the tokens and writes no empty braces', () {
    session.setComment(NodePath.of([0]), '');
    expect(session.commentAt(NodePath.of([0])), '[%eval 0.30]');
    session.setComment(NodePath.of([0, 1]), ''); // 2. Nc3 {Closed}
    expect(session.commentAt(NodePath.of([0, 1])), isNull);
    expect(writeChapter(session.chapter!), isNot(contains('{}')));
  });

  test('the same words again are not an edit', () async {
    session.setComment(NodePath.of([0, 1]), 'Closed');
    await pumpEventQueue();
    expect(fixture.store.requestedSaves, isEmpty);
    expect(notifications, 0);
  });

  test('at the root the comment is the introduction', () async {
    await open(whiteChapter);
    expect(session.commentAt(const NodePath.root()), contains('1... d5.'));
    session.setComment(const NodePath.root(), 'Read this first');
    await pumpEventQueue();
    expect(fixture.onDisk, contains('{Read this first} 1. d4'));
  });
}
