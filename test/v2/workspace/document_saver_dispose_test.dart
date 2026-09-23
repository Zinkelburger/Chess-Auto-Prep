// The saver going away in the middle of its work: when the window closes
// with a write on its way, or a document is torn down under an undo. What
// is already with the store lands; nothing is said afterwards; nothing
// hangs.
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

void main() {
  final sicilian = NodePath.of([0]);

  test('a write on its way when the saver goes still lands, and the saver '
      'says nothing after', () async {
    final fixture = await openSession(blackChapter);
    fixture.store.hold = true;
    fixture.session.setComment(sicilian, 'held');
    await pumpEventQueue();
    expect(fixture.store.waiting, 1, reason: 'the write is with the store');
    var spoken = 0;
    fixture.saver.addListener(() => spoken++);
    fixture.dispose();
    fixture.store.releaseAll();
    await pumpEventQueue();
    expect(fixture.onDisk, contains('{held '));
    expect(spoken, 0);
    await fixture.saver.flush().timeout(const Duration(seconds: 1));
  });

  test('a draft still on its clock when the saver goes is not written: '
      'whoever closes the window flushes first', () async {
    final fixture = await openSession(
      blackChapter,
      delay: const Duration(seconds: 1),
    );
    fixture.session.setComment(sicilian, 'late');
    expect(fixture.saver.settled, isFalse);
    fixture.dispose();
    await pumpEventQueue();
    expect(fixture.store.requestedSaves, isEmpty);
    expect(fixture.onDisk, isNot(contains('{late ')));
  });

  test('an undo on its way when the saver goes is refused, and the store '
      'keeps what it did', () async {
    final fixture = await openSession(blackChapter);
    fixture.session.setComment(sicilian, 'one');
    await pumpEventQueue();
    expect(fixture.onDisk, contains('{one '));
    fixture.store.hold = true;
    final undo = fixture.saver.undo();
    await pumpEventQueue();
    expect(fixture.store.waiting, 1, reason: 'the restore is with the store');
    fixture.dispose();
    fixture.store.releaseAll();
    expect(await undo, isA<UndoRefused>());
    expect(
      fixture.onDisk,
      isNot(contains('{one ')),
      reason: 'the store restored the version it was asked to',
    );
  });
}
