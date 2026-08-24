/// "Last downloaded" belongs to a username, not to a site.
library;

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('changing a username drops the old account\'s download date', () {
    final state = AppState();
    addTearDown(state.dispose);

    state.setChesscomUsername('me');
    state.setChesscomLastFetch(DateTime(2026, 8, 22));
    expect(state.chesscomLastFetch, DateTime(2026, 8, 22));

    state.setChesscomUsername('someone_else');
    expect(
      state.chesscomLastFetch,
      isNull,
      reason: 'the new name has never been downloaded',
    );
  });

  test('re-saving the same username keeps its download date', () {
    final state = AppState();
    addTearDown(state.dispose);

    state.setLichessUsername('me');
    state.setLichessLastFetch(DateTime(2026, 8, 22));

    // The accounts dialog writes both names on every Save, unchanged or not.
    state.setLichessUsername('me');
    expect(state.lichessLastFetch, DateTime(2026, 8, 22));
  });
}
