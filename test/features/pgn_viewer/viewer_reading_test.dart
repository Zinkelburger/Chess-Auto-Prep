import 'package:chess_auto_prep/chess/pgn/collection_player.dart';
import 'package:chess_auto_prep/chess/pgn/game_order.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/reading_place.dart';
import 'package:chess_auto_prep/features/pgn_viewer/viewer_reading.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/workspace/explorer/file_filter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/session_fixture.dart';

void main() {
  test('a place that cannot be looked for in a long file says so and leaves '
      'the file open where it opened', () async {
    // Long enough that the place is looked for off the UI isolate.
    final text = [
      for (var i = 0; i < 520; i++) '[Event "Game $i"]\n\n1. e4 e5 *\n',
    ].join('\n');
    final fixture = await openSession(text);
    addTearDown(fixture.dispose);
    final filter = FileFilter(fixture.session);
    addTearDown(filter.dispose);
    var changes = 0;
    final reading = ViewerReading(
      session: fixture.session,
      filter: filter,
      pending: PendingWrites(),
      store: null,
      activePath: () => fixture.ref.path,
      sort: () => GameOrder.fileOrder,
      setSort: (_) {},
      perspective: () => const FollowCollectionPlayer(),
      changed: () => changes++,
      locateElsewhere: (place, games) async =>
          throw StateError('Isolate exited'),
    );
    addTearDown(reading.dispose);
    final shown = fixture.session.game;

    await reading.restore(
      ReadingPlace(
        game: 300,
        key: 'k',
        path: NodePath.of(const [0]),
        sort: GameOrder.fileOrder,
      ),
      () => true,
    );

    expect(reading.problem, 'Could not find your place in this file.');
    expect(changes, greaterThan(0));
    expect(fixture.session.game, shown);
  });
}
