import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/workspace/save_queue.dart';
import 'package:flutter_test/flutter_test.dart';

EditScope games(Set<int> rewritten) =>
    GamesEdited(GamesWritten(rewritten: rewritten));

Set<int> rewrittenBy(EditScope scope) =>
    (scope as GamesEdited).written.rewritten;

void main() {
  test('two edits are one draft: the newest words, both their games', () {
    final queue = SaveQueue();
    expect(queue.isEmpty, isTrue);
    queue.typed('first', games({0}));
    queue.typed('second', games({1}));
    final draft = queue.take()!;
    expect(draft.text, 'second');
    expect(rewrittenBy(draft.scope), {0, 1});
    expect(queue.isEmpty, isTrue, reason: 'taking empties the queue');
  });

  test('a draft the disk refused goes back behind whatever was typed '
      'meanwhile', () {
    final queue = SaveQueue();
    queue.returned((text: 'refused', scope: games({0})));
    expect(queue.take()!.text, 'refused', reason: 'nothing newer to keep');
    queue.typed('newer', games({1}));
    queue.returned((text: 'refused', scope: games({0})));
    final draft = queue.take()!;
    expect(draft.text, 'newer', reason: 'the newer words are the draft');
    expect(rewrittenBy(draft.scope), {
      0,
      1,
    }, reason: 'but the refused write still names the games it touched');
  });

  test('clearing forgets the draft', () {
    final queue = SaveQueue()..typed('words', games({0}));
    queue.clear();
    expect(queue.isEmpty, isTrue);
    expect(queue.take(), isNull);
  });
}
