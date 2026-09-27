import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/features/settings/models/app_appearance.dart';
import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import 'package:chess_auto_prep/infrastructure/settings/persisted_appearance.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import '../../support/memory_appearance_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'default and restart use a stable key without changing book selections',
    () async {
      SharedPreferences.setMockInitialValues({
        'my_repertoire_white_paths': ['/book.pgn'],
      });
      final owner = SharedPreferencesAppSettingsRepository();
      await owner.appearance.ensureLoaded();
      expect(owner.appearance.state.committed, AppAppearance.dark);
      await owner.appearance.setAppearance(AppAppearance.system);
      final restarted = SharedPreferencesAppSettingsRepository();
      await restarted.appearance.ensureLoaded();
      await restarted.repertoireBooks.ensureLoaded();
      expect(restarted.appearance.state.committed, AppAppearance.system);
      expect(restarted.repertoireBooks.state.committed!.white, ['/book.pgn']);
    },
  );

  for (final invalid in ['unknown', 2, true]) {
    test(
      'invalid stored appearance $invalid is preserved until an explicit choice',
      () async {
        SharedPreferences.setMockInitialValues({
          SharedPreferencesAppearance.key: invalid,
        });
        final repository = PersistedAppearance(SharedPreferencesAppearance());
        await expectLater(repository.ensureLoaded(), throwsFormatException);
        expect(repository.state.phase, SettingsPhase.failed);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.get(SharedPreferencesAppearance.key), invalid);
        await repository.setAppearance(AppAppearance.light);
        expect(repository.state.committed, AppAppearance.light);
      },
    );
  }

  test(
    'slow and reentrant updates serialize without publishing a draft as saved',
    () async {
      final disk = MemoryAppearancePreferences()..gate = Completer<void>();
      final repository = PersistedAppearance(disk);
      await repository.ensureLoaded();
      Future<void>? second;
      final subscription = repository.changes.listen((state) {
        if (state.phase == SettingsPhase.saving && second == null) {
          second = repository.setAppearance(AppAppearance.system);
        }
      });
      addTearDown(subscription.cancel);
      final first = repository.setAppearance(AppAppearance.light);
      await Future<void>.delayed(Duration.zero);
      expect(disk.writes, [AppAppearance.light]);
      expect(repository.state.committed, AppAppearance.dark);
      expect(repository.state.draft, AppAppearance.light);
      disk.gate!.complete();
      await first;
      await second;
      expect(disk.writes, [AppAppearance.light, AppAppearance.system]);
      expect(repository.state.committed, AppAppearance.system);
      expect(repository.state.phase, SettingsPhase.ready);
    },
  );

  test('failed save retains its draft and needs explicit retry', () async {
    final disk = MemoryAppearancePreferences();
    final repository = PersistedAppearance(disk);
    await repository.ensureLoaded();
    disk.writeFails = true;
    await expectLater(
      repository.setAppearance(AppAppearance.light),
      throwsStateError,
    );
    await repository.ensureLoaded();
    expect(disk.writes, [AppAppearance.light]);
    expect(repository.state.committed, AppAppearance.dark);
    expect(repository.state.draft, AppAppearance.light);
    expect(repository.state.phase, SettingsPhase.failed);
    disk.writeFails = false;
    await repository.retry();
    expect(repository.state.committed, AppAppearance.light);
    expect(repository.state.draft, isNull);
  });

  test(
    'post-write error reconciles installed value without silent replay',
    () async {
      final disk = MemoryAppearancePreferences()..failAfterWrite = true;
      final repository = PersistedAppearance(disk);
      await repository.ensureLoaded();
      await expectLater(
        repository.setAppearance(AppAppearance.light),
        throwsStateError,
      );
      expect(repository.state.committed, AppAppearance.light);
      expect(repository.state.phase, SettingsPhase.failed);
      await repository.reload();
      expect(repository.state.phase, SettingsPhase.ready);
      expect(disk.writes, [AppAppearance.light]);
    },
  );

  test('read-back mismatch is a failure rather than a saved choice', () async {
    final disk = MemoryAppearancePreferences()..ignoreWrite = true;
    final repository = PersistedAppearance(disk);
    await repository.ensureLoaded();
    await expectLater(
      repository.setAppearance(AppAppearance.light),
      throwsStateError,
    );
    expect(repository.state.committed, AppAppearance.dark);
    expect(repository.state.draft, AppAppearance.light);
    expect(repository.state.phase, SettingsPhase.failed);
  });

  test(
    'load failure does not retry on subscriptions and reload reads latest value',
    () async {
      final disk = MemoryAppearancePreferences()..readFails = true;
      final repository = PersistedAppearance(disk);
      await expectLater(repository.ensureLoaded(), throwsStateError);
      await repository.ensureLoaded();
      expect(disk.reads, 1);
      disk
        ..readFails = false
        ..value = AppAppearance.system;
      await repository.retry();
      expect(repository.state.committed, AppAppearance.system);
    },
  );
}
