import 'package:chess_auto_prep/chess/generation/expectimax_options.dart';
import 'package:chess_auto_prep/features/settings/lichess_account.dart';
import 'package:chess_auto_prep/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
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
    var diagnostics = 0;
    final rows = [
      for (final group in settingGroups(
        store: store,
        coresAvailable: 8,
        account: account,
        openLogFolder: () {},
        openLicences: () {},
        copyDiagnostics: () => diagnostics++,
      ))
        ...group.rows,
    ];
    NumberSetting number(String label) =>
        rows.firstWhere((row) => row.label == label).control as NumberSetting;

    final action = rows.firstWhere((row) => row.label == 'Diagnostics');
    expect(action.matches('bug report'), isTrue);
    (action.control as ActionSetting).run!();
    expect(diagnostics, 1);

    number('CPU cores').onChanged(3);
    number('Memory').onChanged(512);
    (rows.firstWhere((row) => row.label == 'Board coordinates').control
            as ChoiceSetting<bool>)
        .onChanged(false);

    expect(store.value.engineCores, 3);
    expect(store.value.engineMemoryMb, 512);
    expect(store.value.boardCoordinates, isFalse);

    // The Expectimax rows write what the tab's gear shows.
    number('Depth').onChanged(6);
    number('Later moves').onChanged(3);
    number('Search replies met once in').onChanged(0);
    expect(store.value.expectimax.depth, 6);
    expect(store.value.expectimax.candidateMoves, 3);
    expect(store.value.expectimax.replyFloor, 0);
    (rows.firstWhere((row) => row.label == 'Replies from').control
            as ChoiceSetting<ReplySource>)
        .onChanged(ReplySource.twic);
    number('Fall back to Maia under').onChanged(25);
    expect(store.value.expectimax.replies, ReplySource.twic);
    expect(store.value.expectimax.fallbackUnder, 25);
    expect(store.value.expectimax.maiaFallback, isTrue, reason: 'the default');
    number('Depth').onChanged(0);
    expect(store.value.expectimax.depth, isNull, reason: '0 is no limit');
  });
}
