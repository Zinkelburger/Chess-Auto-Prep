import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/settings/controllers/engine_settings.dart';
import 'package:chess_auto_prep/features/settings/controllers/board_display_settings.dart';
import 'package:chess_auto_prep/features/settings/models/engine_configuration.dart';
import 'package:chess_auto_prep/features/settings/models/board_display_configuration.dart';
import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import '../../support/runtime_settings.dart';

class _RejectingPreferences extends InMemorySharedPreferencesStore {
  _RejectingPreferences() : super.withData({});
  bool rejectHash = true;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (rejectHash && key.endsWith('engine_settings.hash_mb')) return false;
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'platform adapter partial save is reconciled, retried and retained after restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _RejectingPreferences();
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final runtime = RuntimeSettings.preferences();
      addTearDown(runtime.dispose);
      await runtime.load();
      await expectLater(
        runtime.engine.edit({
          'engine_settings.depth': 22,
          'engine_settings.hash_mb': 256,
        }),
        throwsStateError,
      );
      expect(runtime.engine.committed.depth, 22);
      expect(runtime.engine.committed.hashMb, 128);
      expect(runtime.engine.editing.hashMb, 256);
      backend.rejectHash = false;
      await runtime.engine.retry();
      final restarted = RuntimeSettings.preferences();
      addTearDown(restarted.dispose);
      await restarted.load();
      expect(restarted.engine.depth, 22);
      expect(restarted.engine.hashMb, 256);
    },
  );
  test(
    'concurrent panels preserve distinct fields and commit only after storage',
    () async {
      final storage = MemorySettingsSection(EngineConfiguration());
      final owner = EngineSettings(storage);
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      final gate = Completer<void>();
      storage.writeGate = gate.future;
      final a = owner.edit({'engine_settings.depth': 22});
      final b = owner.edit({'engine_settings.multi_pv': 6});
      await Future<void>.delayed(Duration.zero);
      expect(owner.state.phase, SettingsPhase.saving);
      expect(owner.committed.depth, 15);
      expect(owner.editing.depth, 22);
      expect(owner.editing.multiPv, 6);
      gate.complete();
      await Future.wait([a, b]);
      expect(owner.committed.depth, 22);
      expect(owner.committed.multiPv, 6);
      expect(storage.writes.map((patch) => patch.changes.keys.single), [
        'engine_settings.depth',
        'engine_settings.multi_pv',
      ]);
    },
  );
  test(
    'failed edit survives reload and another panel edit, then retries',
    () async {
      final storage = MemorySettingsSection(EngineConfiguration());
      final owner = EngineSettings(storage);
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      final failure = storage.failure = StateError('disk unavailable');
      await expectLater(
        owner.edit({'engine_settings.depth': 22}),
        throwsStateError,
      );
      expect(owner.committed.depth, 15);
      expect(owner.editing.depth, 22);
      await owner.reload();
      expect(owner.state.error, same(failure));
      storage.failure = null;
      await owner.edit({'engine_settings.multi_pv': 6});
      expect(owner.state.phase, SettingsPhase.failed);
      expect(owner.committed.depth, 15);
      expect(owner.committed.multiPv, 6);
      await owner.retry();
      expect(owner.state.phase, SettingsPhase.ready);
      expect(owner.committed.depth, 22);
      expect(owner.committed.multiPv, 6);
      final restarted = EngineSettings(storage);
      addTearDown(restarted.dispose);
      await restarted.ensureLoaded();
      expect(restarted.committed, owner.committed);
    },
  );
  test(
    'late read cannot overwrite edit queued while preferences load',
    () async {
      final storage = MemorySettingsSection(
        EngineConfiguration({'engine_settings.depth': 19}),
      );
      final owner = EngineSettings(storage);
      addTearDown(owner.dispose);
      final read = Completer<void>();
      storage.readGate = read.future;
      final loading = owner.ensureLoaded();
      final saving = owner.edit({'engine_settings.depth': 25});
      read.complete();
      await Future.wait([loading, saving]);
      expect(owner.committed.depth, 25);
    },
  );
  test(
    'board failed draft never changes effective settings before retry',
    () async {
      final storage = MemorySettingsSection(BoardDisplayConfiguration());
      final owner = BoardDisplaySettings(storage);
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      storage.failure = StateError('not written');
      await expectLater(
        owner.setCoordinates(BoardCoordinates.outside),
        throwsStateError,
      );
      expect(owner.coordinates, BoardCoordinates.inside);
      expect(owner.editing.coordinates, BoardCoordinates.outside);
      storage.failure = null;
      await owner.retry();
      expect(owner.coordinates, BoardCoordinates.outside);
    },
  );
}
