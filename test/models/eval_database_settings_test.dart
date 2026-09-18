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
  @override
  Future<bool> setValue(String type, String key, Object value) {
    if (reject && key.endsWith('eval.lichess.enabled')) {
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
      expect(settings.enableCdbDirect, isTrue);
      expect(settings.cdbDirectPath, '/cdb');
      expect(settings.cdbDirectReadAhead, isTrue);
      expect(settings.enableLichessEvals, isTrue);
      expect(settings.lichessEvalsPath, '/lichess');
      expect(settings.chessDbApiForExpectimax, isTrue);
      expect(settings.expectimaxProbePlies, 60);
      await settings.setExpectimaxProbePlies(-1);
      final restarted = preferencesOwner();
      addTearDown(restarted.dispose);
      await restarted.ensureLoaded();
      expect(restarted.committed, settings.committed);
      expect(restarted.expectimaxProbePlies, 2);
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
        expect(settings.isLoaded, isFalse);
        expect(settings.state.phase, SettingsPhase.failed);
        expect(settings.enableCdbDirect, isFalse);
        expect(settings.enableLichessEvals, isFalse);
        expect(settings.chessDbApiForExpectimax, isFalse);
        SharedPreferences.setMockInitialValues({});
        await settings.retry();
        expect(settings.isLoaded, isTrue);
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
      expect(settings.enableCdbDirect, isFalse);
      expect(settings.cdbDirectPath, isEmpty);
      expect(settings.editing.cdbDirectPath, '/downloaded');
      expect(settings.editing.enableCdbDirect, isTrue);
      expect(settings.editing.cdbDirectReadAhead, isTrue);
      expect(storage.writes.single.changes, {
        'eval.cdbdirect.path': '/downloaded',
        'eval.cdbdirect.enabled': true,
      });
      storage.writeGate!.complete();
      await Future.wait([activate, edit]);
      expect(settings.cdbDirectPath, '/downloaded');
      expect(settings.enableCdbDirect, isTrue);
      expect(settings.cdbDirectReadAhead, isTrue);
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
      expect(settings.enableLichessEvals, isFalse);
      expect(settings.lichessEvalsPath, isEmpty);
      expect(settings.editing.lichessEvalsPath, '/ready');
      expect(settings.state.phase, SettingsPhase.failed);
      storage.writeError = null;
      await settings.setExpectimaxProbePlies(18);
      expect(settings.state.phase, SettingsPhase.failed);
      expect(settings.editing.lichessEvalsPath, '/ready');
      await settings.retry();
      expect(settings.enableLichessEvals, isTrue);
      expect(settings.lichessEvalsPath, '/ready');
      expect(settings.expectimaxProbePlies, 18);
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
      expect(settings.lichessEvalsPath, '/built');
      expect(settings.enableLichessEvals, isFalse);
      expect(settings.editing.enableLichessEvals, isTrue);
      platform.reject = false;
      await settings.retry();
      final restarted = preferencesOwner();
      addTearDown(restarted.dispose);
      await restarted.ensureLoaded();
      expect(restarted.lichessEvalsPath, '/built');
      expect(restarted.enableLichessEvals, isTrue);
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
}
