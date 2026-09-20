import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
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
    session = fixture.session..addListener(() => notifications++);
    notifications = 0;
  }

  setUp(() => open(blackChapter));

  tearDown(() => fixture.dispose());

  test('opening a chapter shows its root from its side', () {
    expect(session.cursor.isRoot, isTrue);
    expect(session.fen.whiteToMove, isFalse);
    expect(session.orientation, Side.black);
    expect(session.currentMove, isNull);
    expect(session.source, fixture.ref);
  });

  test('forward and back walk the main line', () {
    session.forward();
    expect(session.currentMove?.san, 'c5');
    session.forward();
    expect(session.currentMove?.san, 'Nf3');
    session.back();
    expect(session.currentMove?.san, 'c5');
    session.back();
    expect(session.cursor.isRoot, isTrue);
    final before = notifications;
    session.back();
    expect(notifications, before, reason: 'backing off the root does nothing');
  });

  test('goTo ignores paths outside the tree', () {
    session.goTo(NodePath.of([0, 1]));
    expect(session.currentMove?.san, 'Nc3');
    session.goTo(NodePath.of([9]));
    expect(session.currentMove?.san, 'Nc3');
  });

  test('toEnd follows the main line from the cursor; toStart returns', () {
    session.goTo(NodePath.of([0, 0, 1]));
    session.toEnd();
    expect(session.currentMove?.san, 'd4');
    expect(session.cursor, NodePath.of([0, 0, 1, 0]));
    session.toStart();
    expect(session.cursor.isRoot, isTrue);
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
    expect(session.currentMove?.san, 'c5');
    await pumpEventQueue();
    expect(fixture.store.requestedSaves, isEmpty);
  });

  test('a move at the end of a line extends that line', () async {
    session.goTo(NodePath.of([0, 0, 0, 0, 0])); // 1... c5 2. Nf3 d6 3. d4 cxd4
    session.playMove('f3d4');
    expect(session.currentMove?.san, 'Nxd4');
    expect(session.chapter?.gameCount, 2, reason: 'no new line was needed');
    await pumpEventQueue();
    expect(fixture.onDisk, contains('cxd4 4. Nxd4'));
  });

  test('a move at a branch point becomes a line of its own', () async {
    session.goTo(NodePath.of([0]));
    session.playMove('c2c3');
    expect(session.currentMove?.san, 'c3');
    expect(session.chapter?.gameCount, 3);
    await pumpEventQueue();
    expect(fixture.onDisk, contains('1... c5 2. c3'));
    expect(fixture.onDisk, contains('LineID'));
  });

  test('an illegal move changes nothing at all', () async {
    session.playMove('a1a8');
    expect(session.cursor.isRoot, isTrue);
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
