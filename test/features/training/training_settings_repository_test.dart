import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'dart:async';

import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import 'package:chess_auto_prep/features/training/controllers/training_settings_controller.dart';
import 'package:chess_auto_prep/features/training/models/training_configuration.dart';
import 'package:chess_auto_prep/infrastructure/training/preferences_training_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/training_settings.dart';

class _RejectingPreferences extends InMemorySharedPreferencesStore {
  _RejectingPreferences()
    : super.withData({'flutter.trainer_uncapped_default_v1': true});
  bool rejectSpeed = true;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (rejectSpeed && key.endsWith('trainer_move_speed_ms')) return false;
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SET-01 concurrent stale panels preserve edits to independent fields',
    () async {
      final storage = MemoryTrainingSettings();
      final owner = TrainingSettingsController(storage);
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      final baseline = owner.state.committed!;
      final first = owner.apply(
        trainingEdit(baseline, (draft) => draft.moveSpeedMs = 250),
      );
      final second = owner.apply(
        trainingEdit(baseline, (draft) => draft.trainingDepth = 8),
      );
      await Future.wait([first, second]);
      expect(owner.state.committed!.toSettings().moveSpeedMs, 250);
      expect(owner.state.committed!.toSettings().trainingDepth, 8);
      expect(storage.writes[0].changes.keys, [TrainingSetting.moveSpeedMs]);
      expect(storage.writes[1].changes.keys, [TrainingSetting.trainingDepth]);
    },
  );

  test(
    'SET-01 settings projections cannot mutate shared committed state',
    () async {
      final owner = TrainingSettingsController(MemoryTrainingSettings());
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      owner.state.committed!.toSettings().moveSpeedMs = 100;
      expect(owner.state.committed!.toSettings().moveSpeedMs, 700);
    },
  );

  test(
    'SET-01 failed edit stays draft until explicit retry confirms persistence',
    () async {
      final storage = MemoryTrainingSettings()..failWrites = true;
      final owner = TrainingSettingsController(storage);
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      final edit = trainingEdit(
        owner.state.committed!,
        (draft) => draft.moveSpeedMs = 250,
      );
      await expectLater(owner.apply(edit), throwsStateError);
      expect(owner.state.phase, SettingsPhase.failed);
      expect(owner.state.committed!.toSettings().moveSpeedMs, 700);
      expect(owner.state.draft!.toSettings().moveSpeedMs, 250);
      await owner.ensureLoaded();
      expect(
        storage.writes,
        hasLength(1),
        reason: 'reading state never retries a save',
      );
      storage.failWrites = false;
      await owner.retry();
      expect(owner.state.phase, SettingsPhase.ready);
      expect(owner.state.draft, isNull);
      expect(owner.state.committed!.toSettings().moveSpeedMs, 250);
    },
  );

  test(
    'SET-01 unrelated successful edit preserves failed draft for later retry',
    () async {
      final storage = MemoryTrainingSettings()..failWrites = true;
      final owner = TrainingSettingsController(storage);
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      final initial = owner.state.committed!;
      await expectLater(
        owner.apply(trainingEdit(initial, (draft) => draft.moveSpeedMs = 250)),
        throwsStateError,
      );
      storage.failWrites = false;
      await owner.apply(
        trainingEdit(initial, (draft) => draft.trainingDepth = 8),
      );
      expect(owner.state.phase, SettingsPhase.failed);
      expect(owner.state.committed!.toSettings().moveSpeedMs, 700);
      expect(owner.state.draft!.toSettings().moveSpeedMs, 250);
      expect(owner.state.draft!.toSettings().trainingDepth, 8);
      await owner.retry();
      expect(owner.state.committed!.toSettings().moveSpeedMs, 250);
      expect(owner.state.committed!.toSettings().trainingDepth, 8);
    },
  );

  test('SET-01 newer edit to failed field supersedes that draft', () async {
    final storage = MemoryTrainingSettings()..failWrites = true;
    final owner = TrainingSettingsController(storage);
    addTearDown(owner.dispose);
    await owner.ensureLoaded();
    final initial = owner.state.committed!;
    await expectLater(
      owner.apply(trainingEdit(initial, (draft) => draft.moveSpeedMs = 250)),
      throwsStateError,
    );
    storage.failWrites = false;
    await owner.apply(
      trainingEdit(initial, (draft) => draft.moveSpeedMs = 900),
    );
    expect(owner.state.phase, SettingsPhase.ready);
    expect(owner.state.committed!.toSettings().moveSpeedMs, 900);
  });

  test(
    'SET-01 delayed reload cannot overwrite an edit submitted behind it',
    () async {
      final storage = MemoryTrainingSettings();
      final owner = TrainingSettingsController(storage);
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      final initial = owner.state.committed!;
      final gate = Completer<TrainingConfiguration>();
      storage.readGate = gate;
      final loading = owner.reload();
      final saving = owner.apply(
        trainingEdit(initial, (draft) => draft.moveSpeedMs = 250),
      );
      await Future<void>.delayed(Duration.zero);
      expect(owner.state.phase, SettingsPhase.loading);
      gate.complete(initial);
      await Future.wait([loading, saving]);
      expect(owner.state.committed!.toSettings().moveSpeedMs, 250);
    },
  );

  test(
    'SET-01 storage restart retains field edits and previous values',
    () async {
      SharedPreferences.setMockInitialValues({
        'trainer_uncapped_default_v1': true,
        'trainer_reviews_per_session': 37,
      });
      final owner = TrainingSettingsController(PreferencesTrainingSettings());
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      final initial = owner.state.committed!;
      await Future.wait([
        owner.apply(trainingEdit(initial, (draft) => draft.moveSpeedMs = 250)),
        owner.apply(trainingEdit(initial, (draft) => draft.trainingDepth = 8)),
      ]);
      final restarted = TrainingSettingsController(
        PreferencesTrainingSettings(),
      );
      addTearDown(restarted.dispose);
      await restarted.ensureLoaded();
      final settings = restarted.state.committed!.toSettings();
      expect(settings.moveSpeedMs, 250);
      expect(settings.trainingDepth, 8);
      expect(settings.reviewsPerSession, 37);
    },
  );

  test(
    'SET-01 old default migration preserves explicit post-migration choices',
    () async {
      SharedPreferences.setMockInitialValues({
        'trainer_new_lines_per_session': 10,
        'trainer_reviews_per_session': 40,
      });
      final owner = TrainingSettingsController(PreferencesTrainingSettings());
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      final migrated = owner.state.committed!;
      expect(migrated.toSettings().newLinesPerSession, 0);
      expect(migrated.toSettings().reviewsPerSession, 0);
      await owner.apply(
        trainingEdit(migrated, (draft) => draft.newLinesPerSession = 10),
      );
      expect(
        (await PreferencesTrainingSettings().read())
            .toSettings()
            .newLinesPerSession,
        10,
      );
    },
  );
  test(
    'SET-01 native false write reconciles partial commit and retries retained fields',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _RejectingPreferences();
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final owner = TrainingSettingsController(PreferencesTrainingSettings());
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      final change = trainingEdit(owner.state.committed!, (draft) {
        draft.correctStreakThreshold = 5;
        draft.moveSpeedMs = 250;
      });
      await expectLater(owner.apply(change), throwsStateError);
      expect(owner.state.phase, SettingsPhase.failed);
      expect(owner.state.committed!.toSettings().correctStreakThreshold, 5);
      expect(owner.state.committed!.toSettings().moveSpeedMs, 700);
      expect(owner.state.draft!.toSettings().moveSpeedMs, 250);
      backend.rejectSpeed = false;
      await owner.retry();
      final restored = (await PreferencesTrainingSettings().read())
          .toSettings();
      expect(restored.correctStreakThreshold, 5);
      expect(restored.moveSpeedMs, 250);
    },
  );
  test('SET-01 reload retains a failed edit, reason and retry draft', () async {
    final storage = MemoryTrainingSettings()..failWrites = true;
    final owner = TrainingSettingsController(storage);
    addTearDown(owner.dispose);
    await owner.ensureLoaded();
    await expectLater(
      owner.apply(
        trainingEdit(
          owner.state.committed!,
          (draft) => draft.moveSpeedMs = 250,
        ),
      ),
      throwsStateError,
    );
    final failure = owner.state.error;
    await owner.reload();
    expect(owner.state.phase, SettingsPhase.failed);
    expect(owner.state.error, same(failure));
    expect(owner.state.draft!.toSettings().moveSpeedMs, 250);
    expect(storage.writes, hasLength(1));
  });
}
