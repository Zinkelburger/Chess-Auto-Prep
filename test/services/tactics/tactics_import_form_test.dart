import 'package:chess_auto_prep/services/tactics/tactics_import_coordinator.dart';
import 'package:chess_auto_prep/services/tactics/tactics_import_form.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults: 20 recent games, depth 15, given cores', () {
    final form = TacticsImportForm(defaultCores: 4);
    expect(form.count, 20);
    expect(form.depth, 15);
    expect(form.cores, 4);
    expect(form.fetchMode, TacticsImportMode.recent);
    expect(form.fieldsValid, isTrue);
    form.dispose();
  });

  test('paramsFor builds recent-mode params from the fields', () {
    final form = TacticsImportForm(defaultCores: 2);
    form.lichessUser.text = '  someone  ';
    form.fetchCount.text = '50';
    form.depthText.text = '18';

    final params = form.paramsFor(TacticsImportSource.lichess);
    expect(params.username, 'someone', reason: 'trimmed');
    expect(params.maxGames, 50);
    expect(params.depth, 18);
    expect(params.cores, 2);
    expect(params.since, isNull);
    form.dispose();
  });

  test('paramsFor in since-date mode passes the date and caps games', () {
    final form = TacticsImportForm();
    form.chessComUser.text = 'player';
    final date = DateTime(2026, 1, 1);
    form.setFetchMode(TacticsImportMode.sinceDate);
    form.setSinceDate(date);

    final params = form.paramsFor(TacticsImportSource.chessCom);
    expect(params.username, 'player');
    expect(params.mode, TacticsImportMode.sinceDate);
    expect(params.since, date);
    expect(params.maxGames, 200);
    form.dispose();
  });

  test('depth and cores getters clamp out-of-range input', () {
    final form = TacticsImportForm(defaultCores: 2);
    form.depthText.text = '99';
    expect(form.depth, 25);
    form.depthText.text = 'abc';
    expect(form.depth, 15, reason: 'falls back to default');
    form.coresText.text = '0';
    expect(form.cores, 1);
    form.dispose();
  });

  test('validation: invalid depth flips validity immediately, error is '
      'debounced', () async {
    final form = TacticsImportForm();
    form.validateDepth('99');
    expect(form.depthValid, isFalse);
    expect(form.depthError, isNull, reason: 'error text debounced');

    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(form.depthError, 'Must be 1–25');

    form.validateDepth('20');
    expect(form.depthValid, isTrue);
    expect(form.depthError, isNull);
    expect(form.fieldsValid, isTrue);
    form.dispose();
  });

  test('prefs round-trip restores count/depth/cores', () async {
    SharedPreferences.setMockInitialValues({});
    final form = TacticsImportForm();
    form.fetchCount.text = '77';
    form.depthText.text = '21';
    form.coresText.text = '3';
    await form.savePrefs();
    form.dispose();

    final restored = TacticsImportForm();
    await restored.loadPrefs();
    expect(restored.fetchCount.text, '77');
    expect(restored.depthText.text, '21');
    expect(restored.coresText.text, '3');
    restored.dispose();
  });
}
