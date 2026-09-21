import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';
import '../support/study_fixture.dart';

void main() {
  late SessionFixture fixture;
  late DocumentSession session;

  tearDown(() => fixture.dispose());

  test(
    'showGame puts another game of the file on the board at its root',
    () async {
      fixture = await openSession(twoChapterStudy);
      session = fixture.session;
      await session.open(fixture.ref, game: 0);
      session.forward();
      expect(session.cursor.isRoot, isFalse);
      session.showGame(1);
      expect(session.game, 1);
      expect(session.cursor.isRoot, isTrue);
      expect(session.tree?.children.single.san, 'd4');
      expect(session.source, fixture.ref);
      expect(session.chapter?.lines.length, 2);
    },
  );

  test(
    'a game the file does not have, or the one showing, changes nothing',
    () async {
      fixture = await openSession(twoChapterStudy);
      session = fixture.session;
      await session.open(fixture.ref, game: 0);
      var notified = 0;
      session.addListener(() => notified++);
      session.showGame(2);
      session.showGame(-1);
      session.showGame(0);
      expect(notified, 0);
      expect(session.game, 0);
    },
  );

  test('a merged chapter has no other game to show', () async {
    fixture = await openSession(blackChapter);
    session = fixture.session;
    session.showGame(1);
    expect(session.game, isNull);
    expect(
      session.tree?.rootFen.value,
      startsWith('rnbqkbnr/pppppppp/8/8/4P3'),
    );
  });

  test(
    'a draft typed on one game reaches the file after showing another',
    () async {
      fixture = await openSession(
        twoChapterStudy,
        delay: const Duration(days: 1),
      );
      session = fixture.session;
      await session.open(fixture.ref, game: 0);
      session.setComment(const NodePath.root(), 'Rooks first');
      session.showGame(1);
      expect(session.game, 1);
      await fixture.saver.flush();
      expect(fixture.onDisk, contains('Rooks first'));
      expect(fixture.onDisk, contains('1. d4 d5 *'));
    },
  );
}
