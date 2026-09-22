import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
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

class _FailingRead extends MemorySettingsSection<EngineConfiguration> {
  _FailingRead()
    : super(EngineConfiguration({'engine_lifecycle.toggle_on': false}));
  bool fail = true;
  int reads = 0;
  @override
  Future<EngineConfiguration> read() async {
    reads++;
    if (fail) throw StateError('preferences unavailable');
    return super.read();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('failed initial reads cannot masquerade as loaded defaults', () async {
    final storage = _FailingRead();
    final owner = EngineSettings(storage);
    addTearDown(owner.dispose);
    await expectLater(owner.ensureLoaded(), throwsStateError);
    await expectLater(owner.ensureLoaded(), throwsStateError);
    expect(storage.reads, 2);
    expect(owner.state.committed, isNull);
    expect(owner.state.phase, SettingsPhase.failed);
    storage.fail = false;
    final gate = Completer<void>();
    storage.readGate = gate.future;
    final first = owner.ensureLoaded();
    final concurrent = owner.ensureLoaded();
    expect(concurrent, same(first));
    gate.complete();
    await Future.wait([first, concurrent]);
    expect(storage.reads, 3);
    expect(owner.committed.enabled, isFalse);
    expect(owner.state.phase, SettingsPhase.ready);
  });

  test(
    'runtime cannot enable from defaults after a failed settings read',
    () async {
      final storage = _FailingRead();
      final owner = EngineSettings(storage);
      final runtime = EngineRuntime(
        settings: owner,
        createConnection: () async => null,
      );
      addTearDown(owner.dispose);
      addTearDown(runtime.dispose);
      await expectLater(owner.ensureLoaded(), throwsStateError);
      await expectLater(
        runtime.lifecycle.loadPersistedState(),
        throwsStateError,
      );
      await runtime.lifecycle.resume();
      expect(runtime.lifecycle.state, EngineState.off);
      expect(owner.state.committed, isNull);
      storage.fail = false;
      await runtime.lifecycle.loadPersistedState();
      await runtime.lifecycle.resume();
      expect(owner.committed.enabled, isFalse);
      expect(runtime.lifecycle.state, EngineState.off);
    },
  );

  test('setters and explicit edits share numeric normalization', () async {
    final storage = MemorySettingsSection(EngineConfiguration(const {}, 4));
    final owner = EngineSettings(storage, maxCores: 4);
    addTearDown(owner.dispose);
    await owner.ensureLoaded();
    owner.cores = 9999;
    owner.hashMb = 0;
    owner.depth = 0;
    owner.multiPv = 9999;
    owner.maxAnalysisMoves = 0;
    owner.maiaElo = 0;
    owner.stockfishTopN = 0;
    // Reload is queued after all submitted edits, including save confirmation.
    await owner.reload();
    final normalized = EngineConfiguration({
      'engine_settings.cores': 9999,
      'engine_settings.hash_mb': 0,
      'engine_settings.depth': 0,
      'engine_settings.multi_pv': 9999,
      'engine_settings.max_analysis_moves': 0,
      'engine_settings.maia_elo': 0,
      'engine_settings.stockfish_top_n': 0,
    }, 4);
    expect(owner.committed, normalized);
    final restarted = EngineSettings(storage, maxCores: 4);
    addTearDown(restarted.dispose);
    await restarted.ensureLoaded();
    expect(restarted.committed, normalized);
  });

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
    'admitted edits settle after disposal without notifying or admitting new edits',
    () async {
      final storage = MemorySettingsSection(EngineConfiguration());
      final owner = EngineSettings(storage);
      await owner.ensureLoaded();
      var notifications = 0;
      owner.addListener(() => notifications++);
      final gate = Completer<void>();
      storage.writeGate = gate.future;
      final first = owner.edit({'engine_settings.depth': 22});
      final second = owner.edit({'engine_settings.multi_pv': 6});
      await Future<void>.delayed(Duration.zero);
      expect(storage.writes, hasLength(1));
      owner.dispose();
      final atDisposal = notifications;
      await expectLater(
        owner.edit({'engine_settings.depth': 30}),
        throwsStateError,
      );
      gate.complete();
      await Future.wait([first, second]);
      expect(notifications, atDisposal);
      expect(storage.writes, hasLength(2));
      final restarted = EngineSettings(storage);
      addTearDown(restarted.dispose);
      await restarted.ensureLoaded();
      expect(restarted.depth, 22);
      expect(restarted.multiPv, 6);
    },
  );
  test(
    'an edit submitted by a listener queues behind the active save',
    () async {
      final storage = MemorySettingsSection(EngineConfiguration());
      final owner = EngineSettings(storage);
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      Future<void>? followup;
      owner.addListener(() {
        if (followup == null && owner.state.phase == SettingsPhase.saving) {
          followup = owner.edit({'engine_settings.multi_pv': 6});
        }
      });
      await owner.edit({'engine_settings.depth': 22});
      expect(followup, isNotNull);
      await followup;
      expect(owner.depth, 22);
      expect(owner.multiPv, 6);
      expect(storage.writes.map((patch) => patch.changes.keys.single), [
        'engine_settings.depth',
        'engine_settings.multi_pv',
      ]);
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
