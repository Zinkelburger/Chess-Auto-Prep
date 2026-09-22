import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/undo_history.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';

/// The receipt a save from [before] to [after] would bring back.
Receipt saved(String before, String after) => Receipt(
  committed: scriptedRevision(after),
  before: before,
  beforeRevision: scriptedRevision(before),
);

void main() {
  test('keeps the newest receipts and no more than its depth', () {
    final history = UndoHistory();
    expect(history.isEmpty, isTrue);
    for (var i = 0; i <= UndoHistory.depth; i++) {
      history.keep(saved('v$i', 'v${i + 1}'));
    }
    expect(history.newest?.before, 'v${UndoHistory.depth}');
    // The first receipt went when the one past the depth came in.
    var steps = 0;
    while (!history.isEmpty) {
      history.tookBack(history.newest!, saved('', ''));
      steps++;
    }
    expect(steps, UndoHistory.depth);
  });

  test('taking a save back leaves the one before it undoable against the '
      'version just written', () {
    // A → B → C on disk. Undoing C restores B's bytes, but as a new write,
    // so the file's revision is not B's old one; the receipt for A → B must
    // now expect that new revision or the next undo would be refused as a
    // conflict.
    final history = UndoHistory()
      ..keep(saved('A', 'B'))
      ..keep(saved('B', 'C'));
    final restored = Receipt(
      committed: Revision('B-again'),
      before: 'C',
      beforeRevision: scriptedRevision('C'),
    );
    history.tookBack(history.newest!, restored);
    final next = history.newest!;
    expect(next.before, 'A');
    expect(next.beforeRevision, scriptedRevision('A'));
    expect(next.committed, Revision('B-again'));
  });

  test('a receipt that does not chain to the one taken back is left '
      'alone', () {
    // Something outside wrote between the two saves, so the older receipt
    // names a revision the undo did not put back; it stays as it is and
    // will be refused as the conflict it is.
    final history = UndoHistory()
      ..keep(saved('A', 'B'))
      ..keep(saved('X', 'C'));
    history.tookBack(history.newest!, saved('C', 'X'));
    expect(history.newest, isNotNull);
    expect(history.newest!.committed, scriptedRevision('B'));
  });

  test('clearing forgets everything', () {
    final history = UndoHistory()..keep(saved('A', 'B'));
    history.clear();
    expect(history.isEmpty, isTrue);
    expect(history.newest, isNull);
  });
}
