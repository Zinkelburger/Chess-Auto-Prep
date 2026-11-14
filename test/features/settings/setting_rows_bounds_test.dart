// The settings rows' own promises: the bounds and steps each number keeps
// to, the rare-reply step that skips one, the Expectimax rows by their
// names, and a diagnostics copy that failed marked as a warning.
import 'package:chess_auto_prep/features/settings/lichess_account.dart';
import 'package:chess_auto_prep/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/search/search_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_login.dart';

void main() {
  late SettingsStore store;
  late LichessAccountState account;

  setUp(() {
    store = SettingsStore();
    account = LichessAccountState(
      login: ScriptedLogin(),
      read: () async => null,
      write: (_) async => true,
    );
    addTearDown(store.dispose);
    addTearDown(account.dispose);
  });

  List<SettingRow> rows({
    DiagnosticCopyState diagnostics = DiagnosticCopyState.idle,
  }) => [
    for (final group in settingGroups(
      store: store,
      coresAvailable: 8,
      account: account,
      openLogFolder: () {},
      openLicences: () {},
      copyDiagnostics: () {},
      diagnostics: diagnostics,
    ))
      ...group.rows,
  ];

  SettingRow row(String label) =>
      rows().firstWhere((row) => row.label == label);
  NumberSetting number(String label) => row(label).control as NumberSetting;

  test('each number keeps to its bounds and step', () {
    expect((number('Move delay').min, number('Move delay').max), (200, 2000));
    expect(number('CPU cores').min, 1);
    expect(number('Opponent rating').step, 100);
    expect(number(SearchSettingCopy.rootMoves.$1).min, 1);
    expect(number(SearchSettingCopy.candidateMoves.$1).min, 1);
  });

  test('the rare-reply step past nothing is one in two, and back', () async {
    void rare(int n) => number(SearchSettingCopy.rare.$1).onChanged(n);
    await store.update(
      store.value.copyWith(
        expectimax: store.value.expectimax.copyWith(rareOnceIn: 0),
      ),
    );
    rare(1);
    expect(store.value.expectimax.rareOnceIn, 2);
    rare(1);
    expect(store.value.expectimax.rareOnceIn, 0);
    rare(5);
    expect(store.value.expectimax.rareOnceIn, 5);
  });

  test('the Expectimax rows go by their names', () {
    final labels = rows().map((row) => row.label);
    expect(labels, contains(SearchSettingCopy.bothSides.$1));
    expect(labels, contains(SearchSettingCopy.source.$1));
  });

  test(
    'a diagnostics copy that failed is a warning; one that worked is not',
    () {
      bool warns(DiagnosticCopyState state) => rows(
        diagnostics: state,
      ).firstWhere((row) => row.label == 'Diagnostics').warn;
      expect(warns(DiagnosticCopyState.failed), isTrue);
      expect(warns(DiagnosticCopyState.copied), isFalse);
    },
  );
}
