import 'package:chess_auto_prep/features/games/services/games_window.dart';
import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/services/tactics/mining_settings.dart';
import 'package:chess_auto_prep/services/tactics/tactics_import_form.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TacticsImportForm build({
    GamesWindowSettings? window,
    MiningSettings? mining,
  }) => TacticsImportForm(
    windowSettings: window ?? GamesWindowSettings.forTest(),
    miningSettings: mining ?? MiningSettings.forTest(),
  );

  test('defaults: the shared last-20-games window, depth 15', () {
    final form = build();
    expect(form.window, const GamesWindow());
    expect(form.gamesText.text, '20');
    expect(form.daysText.text, '2');
    expect(form.depth, MiningSettings.defaultDepth);
    form.dispose();
  });

  test('the form owns neither knob: depth and cores are the shared '
      'settings', () async {
    final mining = MiningSettings.forTest();
    final form = build(mining: mining);

    expect(form.cores, EngineSettings.instance.workers);
    expect(form.depth, mining.depth);

    // Editing the setting (the review strip's steppers) moves the form's view
    // of it, with no second copy to fall out of step.
    SharedPreferences.setMockInitialValues({});
    await mining.setDepth(20);
    expect(form.depth, 20);

    form.dispose();
  });

  test('an external window change lands in the fields', () async {
    SharedPreferences.setMockInitialValues({});
    final window = GamesWindowSettings.forTest();
    final form = build(window: window);

    // Stands in for the home pane's settings dialog applying a new window.
    await window.set(const GamesWindow(games: 7, days: 3));

    expect(form.gamesText.text, '7');
    expect(form.daysText.text, '3');
    form.dispose();
  });

  test('loadPrefs pulls the persisted window and depth into view', () async {
    SharedPreferences.setMockInitialValues({});
    final saved = build();
    await saved.setWindowGames(77);
    saved.dispose();

    final mining = MiningSettings.forTest();
    await mining.setDepth(21);

    final restored = build(mining: mining);
    await restored.loadPrefs();
    expect(restored.window.games, 77);
    expect(restored.depth, 21);
    restored.dispose();
  });
}
