import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'dart:async';

import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import 'package:chess_auto_prep/features/settings/models/section_configuration.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/features/training/controllers/training_settings_controller.dart';
import 'package:chess_auto_prep/features/training/models/training_configuration.dart';
import 'package:chess_auto_prep/infrastructure/training/preferences_training_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/training_settings.dart';

class _RejectingPreferences extends InMemorySharedPreferencesStore {
  _RejectingPreferences({
    Map<String, Object> initial = const {
      'flutter.trainer_uncapped_default_v1': true,
    },
  }) : super.withData(initial);
  bool rejectSpeed = true;
  bool rejectDepthRemoval = false;
  String? rejectedKey;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (rejectSpeed && key.endsWith('trainer_move_speed_ms')) return false;
    if (rejectedKey != null && key.endsWith(rejectedKey!)) return false;
    return super.setValue(type, key, value);
  }

  @override
  Future<bool> remove(String key) {
    if (rejectDepthRemoval && key.endsWith('trainer_training_depth')) {
      return Future.value(false);
    }
    return super.remove(key);
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
      final first = owner.edit(
        trainingEdit(baseline, (draft) => draft.moveSpeedMs = 250),
      );
      final second = owner.edit(
        trainingEdit(baseline, (draft) => draft.trainingDepth = 8),
      );
      await Future.wait([first, second]);
      expect(owner.state.committed!.toSettings().moveSpeedMs, 250);
      expect(owner.state.committed!.toSettings().trainingDepth, 8);
      expect(storage.writes[0].changes.keys, ['trainer_move_speed_ms']);
      expect(storage.writes[1].changes.keys, ['trainer_training_depth']);
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
      await expectLater(owner.edit(edit), throwsStateError);
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
        owner.edit(trainingEdit(initial, (draft) => draft.moveSpeedMs = 250)),
        throwsStateError,
      );
      storage.failWrites = false;
      await owner.edit(
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
      owner.edit(trainingEdit(initial, (draft) => draft.moveSpeedMs = 250)),
      throwsStateError,
    );
    storage.failWrites = false;
    await owner.edit(trainingEdit(initial, (draft) => draft.moveSpeedMs = 900));
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
      final saving = owner.edit(
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
        owner.edit(trainingEdit(initial, (draft) => draft.moveSpeedMs = 250)),
        owner.edit(trainingEdit(initial, (draft) => draft.trainingDepth = 8)),
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
      await owner.edit(
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
      await expectLater(owner.edit(change), throwsStateError);
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
      owner.edit(
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

  test('nullable patch merging preserves explicit clear and absent fields', () {
    final initial = TrainingConfiguration(TrainingSettings(trainingDepth: 8));
    final fullLine = TrainingConfiguration(TrainingSettings());
    final clear = fullLine.changesFrom(initial);
    expect(clear, {'trainer_training_depth': null});
    final merged = SettingsPatch<TrainingConfiguration>({
      'trainer_move_speed_ms': 250,
      'trainer_training_depth': 4,
    }).followedBy(SettingsPatch(clear));
    final result = merged.apply(initial).toSettings();
    expect(result.trainingDepth, isNull);
    expect(result.moveSpeedMs, 250);
    expect(result.autoNext, initial.toSettings().autoNext);
    expect(merged.without(['trainer_move_speed_ms']).changes, {
      'trainer_training_depth': null,
    });
    expect(() => clear.clear(), throwsUnsupportedError);
  });

  test(
    'failed depth removal reconciles partial write and retries only retained fields',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend =
          _RejectingPreferences(
              initial: {
                'flutter.trainer_uncapped_default_v1': true,
                'flutter.trainer_training_depth': 8,
              },
            )
            ..rejectSpeed = false
            ..rejectDepthRemoval = true;
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final owner = TrainingSettingsController(PreferencesTrainingSettings());
      addTearDown(owner.dispose);
      await owner.ensureLoaded();
      await expectLater(
        owner.edit(
          trainingEdit(owner.committed, (draft) {
            draft.correctStreakThreshold = 5;
            draft.trainingDepth = null;
          }),
        ),
        throwsStateError,
      );
      expect(owner.committed.toSettings().correctStreakThreshold, 5);
      expect(owner.committed.toSettings().trainingDepth, 8);
      expect(owner.editing.toSettings().trainingDepth, isNull);
      await owner.edit({'trainer_move_speed_ms': 250});
      expect(owner.state.phase, SettingsPhase.failed);
      expect(owner.editing.toSettings().trainingDepth, isNull);
      backend.rejectDepthRemoval = false;
      await owner.retry();
      expect(owner.committed.toSettings().trainingDepth, isNull);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.containsKey('trainer_training_depth'), isFalse);
      final restarted = TrainingSettingsController(
        PreferencesTrainingSettings(),
      );
      addTearDown(restarted.dispose);
      await restarted.ensureLoaded();
      expect(restarted.committed.toSettings().trainingDepth, isNull);
      expect(restarted.committed.toSettings().moveSpeedMs, 250);
      expect(restarted.committed.toSettings().correctStreakThreshold, 5);
    },
  );

  test(
    'partial cap migration keeps its flag unset and retries before publication',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend =
          _RejectingPreferences(
              initial: {
                'flutter.trainer_new_lines_per_session': 10,
                'flutter.trainer_reviews_per_session': 40,
              },
            )
            ..rejectSpeed = false
            ..rejectedKey = 'trainer_reviews_per_session';
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final owner = TrainingSettingsController(PreferencesTrainingSettings());
      addTearDown(owner.dispose);
      await expectLater(owner.ensureLoaded(), throwsStateError);
      expect(owner.state.committed, isNull);
      expect(owner.state.phase, SettingsPhase.failed);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getInt('trainer_new_lines_per_session'), 0);
      expect(prefs.getInt('trainer_reviews_per_session'), 40);
      expect(prefs.getBool('trainer_uncapped_default_v1'), isNot(isTrue));
      backend.rejectedKey = null;
      await owner.retry();
      expect(owner.committed.toSettings().newLinesPerSession, 0);
      expect(owner.committed.toSettings().reviewsPerSession, 0);
      await prefs.reload();
      expect(prefs.getBool('trainer_uncapped_default_v1'), isTrue);
      await owner.edit({
        'trainer_new_lines_per_session': 10,
        'trainer_reviews_per_session': 40,
      });
      final reloaded = (await PreferencesTrainingSettings().read())
          .toSettings();
      expect(reloaded.newLinesPerSession, 10);
      expect(reloaded.reviewsPerSession, 40);
    },
  );

  test(
    'persisted scalar corruption fails while unknown enum strings retain defaults',
    () async {
      SharedPreferences.setMockInitialValues({
        'trainer_uncapped_default_v1': true,
        'trainer_move_speed_ms': 'wrong type',
      });
      final owner = TrainingSettingsController(PreferencesTrainingSettings());
      addTearDown(owner.dispose);
      await expectLater(owner.ensureLoaded(), throwsA(isA<TypeError>()));
      expect(owner.state.committed, isNull);
      SharedPreferences.setMockInitialValues({
        'trainer_uncapped_default_v1': true,
        'trainer_review_order': 'future-order',
        'trainer_chapter_grouping': 'future-group',
      });
      await owner.retry();
      expect(
        owner.committed.toSettings().reviewOrder,
        TrainingSettings().reviewOrder,
      );
      expect(
        owner.committed.toSettings().chapterGrouping,
        TrainingSettings().chapterGrouping,
      );
    },
  );
}
