import 'package:chess_auto_prep/v2/features/settings/lichess_account.dart';
import 'package:chess_auto_prep/v2/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_login.dart';

void main() {
  test('two changes that land before the rows are built again both stay', () {
    // A number typed into one row is taken when the field loses focus to a
    // click on another row: both land on the rows built before either.
    final store = SettingsStore();
    final account = LichessAccountState(
      login: ScriptedLogin(),
      read: () async => null,
      write: (_) async => true,
    );
    addTearDown(store.dispose);
    addTearDown(account.dispose);
    final rows = [
      for (final group in settingGroups(
        store: store,
        coresAvailable: 8,
        account: account,
        openLogFolder: () {},
      ))
        ...group.rows,
    ];
    NumberSetting number(String label) =>
        rows.firstWhere((row) => row.label == label).control as NumberSetting;

    number('CPU cores').onChanged(3);
    number('Memory').onChanged(512);
    (rows.firstWhere((row) => row.label == 'Board coordinates').control
            as ChoiceSetting<bool>)
        .onChanged(false);

    expect(store.value.engineCores, 3);
    expect(store.value.engineMemoryMb, 512);
    expect(store.value.boardCoordinates, isFalse);
  });
}
