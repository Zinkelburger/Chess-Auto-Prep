import 'package:chess_auto_prep/models/eval_database_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('on-demand expectimax defaults: API off, 12 half-moves', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = EvalDatabaseSettings.instance;
    await settings.load();

    expect(settings.chessDbApiForExpectimax, isFalse);
    expect(
      settings.expectimaxProbePlies,
      EvalDatabaseSettings.defaultExpectimaxProbePlies,
    );

    await settings.setChessDbApiForExpectimax(true);
    await settings.setExpectimaxProbePlies(16);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('expectimax.chessdb_api'), isTrue);
    expect(prefs.getInt('expectimax.probe_plies'), 16);

    await settings.resetToDefaults();
    expect(settings.chessDbApiForExpectimax, isFalse);
    expect(settings.expectimaxProbePlies, 12);
  });
}
