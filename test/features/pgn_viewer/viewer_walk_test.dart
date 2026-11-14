// The viewer's list when the game on the board is not in it: ↑ takes the
// last game the list shows; and the games shown go to a study whole.
import 'package:chess_auto_prep/chess/game_filter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/viewer_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ViewerFixture fixture;

  setUp(() async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
  });
  tearDown(() => fixture.dispose());

  Future<void> hideTheFirst() async {
    fixture.filter.apply(
      const GameFilter(
        rules: [HeaderRule(rule: FilterRule.excludes, value: 'Carlsen')],
      ),
    );
    await pumpEventQueue();
  }

  test('↑ from a game the list hides takes its last game', () async {
    await hideTheFirst();
    final order = fixture.viewer.gameOrder;
    expect(order, hasLength(2));
    expect(order, isNot(contains(0)));
    expect(fixture.session.game, 0);
    fixture.viewer.walk(-1);
    await pumpEventQueue();
    expect(fixture.session.game, order.last);
  });

  test('the games shown go to a study', () async {
    await hideTheFirst();
    expect(fixture.viewer.selectionDrafts(), hasLength(2));
  });
}
