import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/document/undo_history.dart';
import 'package:flutter_test/flutter_test.dart';

Receipt _receipt(int n) => Receipt(
  committed: Revision('r$n'),
  before: 'text $n',
  // Not the save below it, so no undo repoints that one.
  beforeRevision: Revision('elsewhere $n'),
);

void main() {
  test('undo takes back the last twenty saves; the oldest go first', () {
    final history = UndoHistory();
    for (var n = 0; n <= 20; n++) {
      history.keep(_receipt(n), const WholeDocument());
    }
    final kept = <String>[];
    for (var newest = history.newest; newest != null; newest = history.newest) {
      kept.add(newest.receipt.committed.contentHash);
      history.tookBack(newest.receipt, _receipt(99));
    }
    expect(kept, hasLength(20));
    expect(kept.last, 'r1');
  });
}
