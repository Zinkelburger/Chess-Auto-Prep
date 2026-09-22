import 'dart:async';

import 'package:chess_auto_prep/features/settings/controllers/eval_database_settings.dart';
import 'package:chess_auto_prep/features/settings/models/eval_database_configuration.dart';
import 'package:chess_auto_prep/features/settings/models/section_configuration.dart';
import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import 'package:chess_auto_prep/features/settings/repositories/settings_section_storage.dart';
import 'package:chess_auto_prep/infrastructure/settings/preferences_section_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Storage implements SettingsSectionStorage<EvalDatabaseConfiguration> {
  EvalDatabaseConfiguration value = EvalDatabaseConfiguration();
  Completer<void>? writeGate;
  Object? readError;
  Object? writeError;
  final writes = <SettingsPatch<EvalDatabaseConfiguration>>[];
  @override
  Future<EvalDatabaseConfiguration> read() async {
    if (readError case final error?) throw error;
    return value;
  }

  @override
  Future<void> write(SettingsPatch<EvalDatabaseConfiguration> patch) async {
    writes.add(patch);
    await writeGate?.future;
    if (writeError case final error?) throw error;
    value = patch.apply(value);
  }
}

class _RejectActivation extends InMemorySharedPreferencesStore {
  _RejectActivation() : super.withData({});
  bool reject = true;
  String rejectedKey = 'eval.lichess.enabled';
  @override
  Future<bool> setValue(String type, String key, Object value) {
    if (reject && key.endsWith(rejectedKey)) {
      return Future.value(false);
    }
    return super.setValue(type, key, value);
  }
}

EvalDatabaseSettings preferencesOwner() => EvalDatabaseSettings(
  PreferencesSectionStorage(
    keys: EvalDatabaseConfiguration().values.keys.toSet(),
    decode: EvalDatabaseConfiguration.new,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('on-demand expectimax defaults: API off, 12 half-moves', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = preferencesOwner();
    addTearDown(settings.dispose);
    await settings.ensureLoaded();

    expect(settings.committed.chessDbApiForExpectimax, isFalse);
    expect(
      settings.committed.expectimaxProbePlies,
      EvalDatabaseConfiguration.defaultExpectimaxProbePlies,
    );

    await settings.setChessDbApiForExpectimax(true);
    await settings.setExpectimaxProbePlies(16);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('expectimax.chessdb_api'), isTrue);
    expect(prefs.getInt('expectimax.probe_plies'), 16);

    await settings.resetToDefaults();
    expect(settings.committed.chessDbApiForExpectimax, isFalse);
    expect(settings.committed.expectimaxProbePlies, 12);
  });

  test(
    'all seven existing keys survive restart and normalize probe bounds',
    () async {
      SharedPreferences.setMockInitialValues({
        'eval.cdbdirect.enabled': true,
        'eval.cdbdirect.path': '/cdb',
        'eval.cdbdirect.read_ahead': true,
        'eval.lichess.enabled': true,
        'eval.lichess.path': '/lichess',
        'expectimax.chessdb_api': true,
        'expectimax.probe_plies': 999,
      });
      final settings = preferencesOwner();
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      expect(settings.committed.enableCdbDirect, isTrue);
      expect(settings.committed.cdbDirectPath, '/cdb');
      expect(settings.committed.cdbDirectReadAhead, isTrue);
      expect(settings.committed.enableLichessEvals, isTrue);
      expect(settings.committed.lichessEvalsPath, '/lichess');
      expect(settings.committed.chessDbApiForExpectimax, isTrue);
      expect(settings.committed.expectimaxProbePlies, 60);
      await settings.setExpectimaxProbePlies(-1);
      final restarted = preferencesOwner();
      addTearDown(restarted.dispose);
      await restarted.ensureLoaded();
      expect(restarted.committed, settings.committed);
      expect(restarted.committed.expectimaxProbePlies, 2);
      expect(() => restarted.committed.values.clear(), throwsUnsupportedError);
    },
  );

  for (final entry in EvalDatabaseConfiguration().values.entries) {
    test(
      'invalid persisted type for ${entry.key} remains a failed read',
      () async {
        SharedPreferences.setMockInitialValues({
          entry.key: entry.value is String ? true : 'invalid',
          if (entry.key != 'eval.cdbdirect.enabled')
            'eval.cdbdirect.enabled': true,
        });
        final settings = preferencesOwner();
        addTearDown(settings.dispose);
        await expectLater(settings.ensureLoaded(), throwsFormatException);
        expect(settings.state.committed, isNull);
        expect(settings.state.phase, SettingsPhase.failed);
        expect(settings.committed.enableCdbDirect, isFalse);
        expect(settings.committed.enableLichessEvals, isFalse);
        expect(settings.committed.chessDbApiForExpectimax, isFalse);
        SharedPreferences.setMockInitialValues({});
        await settings.retry();
        expect(settings.state.committed, isNotNull);
        expect(settings.state.phase, SettingsPhase.ready);
      },
    );
  }

  test(
    'paired activation and another panel edit publish only after persistence',
    () async {
      final storage = _Storage()..writeGate = Completer<void>();
      final settings = EvalDatabaseSettings(storage);
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      final activate = settings.configureCdbDirectory('/downloaded');
      final edit = settings.setCdbDirectReadAhead(true);
      await Future<void>.delayed(Duration.zero);
      expect(settings.committed.enableCdbDirect, isFalse);
      expect(settings.committed.cdbDirectPath, isEmpty);
      expect(settings.editing.cdbDirectPath, '/downloaded');
      expect(settings.editing.enableCdbDirect, isTrue);
      expect(settings.editing.cdbDirectReadAhead, isTrue);
      expect(storage.writes.single.changes, {
        'eval.cdbdirect.path': '/downloaded',
        'eval.cdbdirect.enabled': true,
      });
      storage.writeGate!.complete();
      await Future.wait([activate, edit]);
      expect(settings.committed.cdbDirectPath, '/downloaded');
      expect(settings.committed.enableCdbDirect, isTrue);
      expect(settings.committed.cdbDirectReadAhead, isTrue);
    },
  );

  test(
    'failed activation keeps the prior runtime and retries its retained draft',
    () async {
      final storage = _Storage()..writeError = StateError('disk unavailable');
      final settings = EvalDatabaseSettings(storage);
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      await expectLater(
        settings.configureLichessDirectory('/ready'),
        throwsStateError,
      );
      expect(settings.committed.enableLichessEvals, isFalse);
      expect(settings.committed.lichessEvalsPath, isEmpty);
      expect(settings.editing.lichessEvalsPath, '/ready');
      expect(settings.state.phase, SettingsPhase.failed);
      storage.writeError = null;
      await settings.setExpectimaxProbePlies(18);
      expect(settings.state.phase, SettingsPhase.failed);
      expect(settings.editing.lichessEvalsPath, '/ready');
      await settings.retry();
      expect(settings.committed.enableLichessEvals, isTrue);
      expect(settings.committed.lichessEvalsPath, '/ready');
      expect(settings.committed.expectimaxProbePlies, 18);
    },
  );

  test(
    'a rejected activation key reconciles partial persistence before retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final platform = _RejectActivation();
      SharedPreferencesStorePlatform.instance = platform;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final settings = preferencesOwner();
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      await expectLater(
        settings.configureLichessDirectory('/built'),
        throwsStateError,
      );
      expect(settings.committed.lichessEvalsPath, '/built');
      expect(settings.committed.enableLichessEvals, isFalse);
      expect(settings.editing.enableLichessEvals, isTrue);
      platform.reject = false;
      await settings.retry();
      final restarted = preferencesOwner();
      addTearDown(restarted.dispose);
      await restarted.ensureLoaded();
      expect(restarted.committed.lichessEvalsPath, '/built');
      expect(restarted.committed.enableLichessEvals, isTrue);
    },
  );

  test(
    'admitted writes settle after disposal but new edits are refused',
    () async {
      final storage = _Storage()..writeGate = Completer<void>();
      final settings = EvalDatabaseSettings(storage);
      await settings.ensureLoaded();
      var notifications = 0;
      settings.addListener(() => notifications++);
      final activation = settings.configureLichessDirectory('/built');
      await Future<void>.delayed(Duration.zero);
      settings.dispose();
      final before = notifications;
      storage.writeGate!.complete();
      await activation;
      expect(storage.value.enableLichessEvals, isTrue);
      expect(notifications, before);
      await expectLater(
        settings.setEnableLichessEvals(false),
        throwsStateError,
      );
    },
  );

  test(
    'clear followed by queued Retry and toggle cannot reactivate A',
    () async {
      final storage = _Storage();
      final settings = EvalDatabaseSettings(storage);
      addTearDown(settings.dispose);
      await settings.configureLichessDirectory('/A');
      storage.writeError = StateError('activation failure');
      await expectLater(
        settings.configureLichessDirectory('/A'),
        throwsStateError,
      );
      storage.writeError = null;
      storage.writeGate = Completer<void>();
      final clear = settings.clearLichessDirectory('/A');
      await Future<void>.delayed(Duration.zero);
      final retry = settings.retry();
      final enable = settings.setEnableLichessEvals(true);
      storage.writeGate!.complete();
      await Future.wait([clear, retry, enable]);
      expect(storage.value.lichessEvalsPath, isEmpty);
      expect(storage.value.enableLichessEvals, isFalse);
      expect(settings.state.phase, SettingsPhase.ready);
      expect(
        storage.writes
            .skip(2)
            .every((p) => p.changes['eval.lichess.path'] == ''),
        isTrue,
      );
    },
  );

  test(
    'disk B survives clearing failed A while unrelated failed edit retries',
    () async {
      final storage = _Storage();
      final settings = EvalDatabaseSettings(storage);
      addTearDown(settings.dispose);
      await settings.configureLichessDirectory('/B');
      storage.writeError = StateError('disk unavailable');
      await expectLater(
        settings.configureLichessDirectory('/A'),
        throwsStateError,
      );
      await expectLater(settings.setExpectimaxProbePlies(19), throwsStateError);
      storage.writeError = null;
      final before = storage.writes.length;
      await settings.clearLichessDirectory('/A');
      expect(storage.writes.length, before);
      expect(settings.committed.lichessEvalsPath, '/B');
      expect(settings.editing.lichessEvalsPath, '/B');
      expect(settings.editing.expectimaxProbePlies, 19);
      expect(settings.state.phase, SettingsPhase.failed);
      await settings.retry();
      expect(storage.writes.last.changes, {'expectimax.probe_plies': 19});
      expect(settings.committed.enableLichessEvals, isTrue);
    },
  );

  test('clearing persisted A preserves a failed newer B selection', () async {
    final storage = _Storage();
    final settings = EvalDatabaseSettings(storage);
    addTearDown(settings.dispose);
    await settings.configureCdbDirectory('/A');
    storage.writeError = StateError('disk unavailable');
    await expectLater(settings.configureCdbDirectory('/B'), throwsStateError);
    storage.writeError = null;
    await settings.clearCdbDirectory('/A');
    expect(settings.committed.cdbDirectPath, isEmpty);
    expect(settings.committed.enableCdbDirect, isFalse);
    expect(settings.editing.cdbDirectPath, '/B');
    expect(settings.editing.enableCdbDirect, isTrue);
    await settings.retry();
    expect(settings.committed.cdbDirectPath, '/B');
    expect(settings.committed.enableCdbDirect, isTrue);
  });

  test('queued B and toggle bind to B after clearing A', () async {
    final storage = _Storage();
    final settings = EvalDatabaseSettings(storage);
    addTearDown(settings.dispose);
    await settings.configureCdbDirectory('/A');
    storage.writeGate = Completer<void>();
    final clear = settings.clearCdbDirectory('/A');
    final newer = settings.configureCdbDirectory('/B');
    final disable = settings.setEnableCdbDirect(false);
    storage.writeGate!.complete();
    await Future.wait([clear, newer, disable]);
    expect(settings.committed.cdbDirectPath, '/B');
    expect(settings.committed.enableCdbDirect, isFalse);
    expect(storage.writes.last.changes, {
      'eval.cdbdirect.path': '/B',
      'eval.cdbdirect.enabled': false,
    });
  });

  test(
    'failed conditional clear preserves existing activation retry',
    () async {
      final storage = _Storage();
      final settings = EvalDatabaseSettings(storage);
      addTearDown(settings.dispose);
      await settings.configureCdbDirectory('/A');
      storage.writeError = StateError('disk unavailable');
      await expectLater(settings.configureCdbDirectory('/A'), throwsStateError);
      await expectLater(settings.clearCdbDirectory('/A'), throwsStateError);
      expect(settings.editing.cdbDirectPath, '/A');
      expect(settings.editing.enableCdbDirect, isTrue);
      storage.writeError = null;
      await settings.retry();
      expect(storage.writes.last.changes, {
        'eval.cdbdirect.path': '/A',
        'eval.cdbdirect.enabled': true,
      });
    },
  );

  test(
    'partial clear reconciles disabled A without a generic clear retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final platform = _RejectActivation()..reject = false;
      SharedPreferencesStorePlatform.instance = platform;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final settings = preferencesOwner();
      addTearDown(settings.dispose);
      await settings.configureLichessDirectory('/A');
      platform
        ..reject = true
        ..rejectedKey = 'eval.lichess.path';
      await expectLater(settings.clearLichessDirectory('/A'), throwsStateError);
      expect(settings.committed.lichessEvalsPath, '/A');
      expect(settings.committed.enableLichessEvals, isFalse);
      // Retry reloads; it must not replay the clear, which still cannot persist.
      await settings.retry();
      expect(settings.committed.lichessEvalsPath, '/A');
      platform.reject = false;
      await settings.configureLichessDirectory('/B');
      await settings.retry();
      expect(settings.committed.lichessEvalsPath, '/B');
      expect(settings.committed.enableLichessEvals, isTrue);
    },
  );

  test(
    'unknown initial selection refuses clear and toggle without writes',
    () async {
      final storage = _Storage()..readError = StateError('unreadable');
      final settings = EvalDatabaseSettings(storage);
      addTearDown(settings.dispose);
      await expectLater(settings.clearCdbDirectory('/A'), throwsStateError);
      await expectLater(settings.setEnableCdbDirect(true), throwsStateError);
      expect(storage.writes, isEmpty);
      expect(settings.state.committed, isNull);
      expect(settings.state.phase, SettingsPhase.failed);
      storage.readError = null;
      await settings.retry();
      expect(settings.state.phase, SettingsPhase.ready);
      expect(settings.committed.enableCdbDirect, isFalse);
    },
  );

  test(
    'explicit path-field clear disables the selected database together',
    () async {
      final storage = _Storage();
      final settings = EvalDatabaseSettings(storage);
      addTearDown(settings.dispose);
      await settings.configureCdbDirectory('/A');
      await settings.clearCdbSelection();
      expect(storage.writes.last.changes, {
        'eval.cdbdirect.enabled': false,
        'eval.cdbdirect.path': '',
      });
      expect(settings.committed.cdbDirectPath, isEmpty);
      expect(settings.committed.enableCdbDirect, isFalse);
    },
  );

  test(
    'toggle preserves displayed failed B and unrelated failed fields',
    () async {
      final storage = _Storage();
      final settings = EvalDatabaseSettings(storage);
      addTearDown(settings.dispose);
      await settings.configureCdbDirectory('/A');
      storage.writeError = StateError('disk unavailable');
      await expectLater(settings.configureCdbDirectory('/B'), throwsStateError);
      await expectLater(settings.setExpectimaxProbePlies(19), throwsStateError);
      expect(settings.editing.cdbDirectPath, '/B');
      expect(settings.committed.cdbDirectPath, '/A');
      storage.writeError = null;
      await settings.setEnableCdbDirect(false);
      expect(storage.writes.last.changes, {
        'eval.cdbdirect.path': '/B',
        'eval.cdbdirect.enabled': false,
      });
      expect(settings.committed.cdbDirectPath, '/B');
      expect(settings.committed.enableCdbDirect, isFalse);
      expect(settings.state.phase, SettingsPhase.failed);
      expect(settings.editing.expectimaxProbePlies, 19);
      await settings.retry();
      expect(storage.writes.last.changes, {'expectimax.probe_plies': 19});
      expect(settings.committed.cdbDirectPath, '/B');
      expect(settings.committed.enableCdbDirect, isFalse);
    },
  );
}
