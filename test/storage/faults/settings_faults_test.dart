// settings.json written under a fault at every effect: the app starts,
// reads its settings, and the user changes one. The file is written whole
// (`SettingsStore`), so a fault leaves the old settings or the new ones,
// never a mix, and never the defaults in place of what the user chose. A
// store keeps the settings it read for the session, so the app's retry is
// the next start making the change again. See fault_matrix.dart for the
// families.
@TestOn('linux')
// Every case runs a fault matrix of isolates: four times the default
// 30 s, for a busy CI runner.
@Timeout.factor(4)
library;

import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/contracts.dart';
import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/record_stores.dart';
import '../../support/faulty_disk/scenario.dart';

/// A start that reads the settings, then five engine lines chosen; what the
/// settings page then says went wrong, if anything.
Future<String?> _change(RecordStores s) async {
  final store = s.settings();
  await store.load();
  await store.update(store.value.copyWith(engineLines: 5));
  final problem = store.problem;
  store.dispose();
  return problem;
}

Verdict _saved(String? problem) =>
    problem == null ? Verdict.committed : Verdict.unknown;

Future<String> _settings(RecordStores s) => s.settingsNow();

const _scenario = StorageScenario<RecordStores, String?>(
  name: 'change a setting',
  seed: seedRecordProfile,
  open: RecordStores.open,
  command: _change,
  verdict: _saved,
  retry: _change,
  firstRead: _settings,
  probes: recordProbes,
);

void main() => faultMatrix(_scenario);
