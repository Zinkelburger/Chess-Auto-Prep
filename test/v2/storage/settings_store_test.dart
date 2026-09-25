import 'package:chess_auto_prep/v2/chess/training/training_options.dart';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('v2-settings-');
  });

  tearDown(() => support.delete(recursive: true));

  File file() => File(p.join(support.path, 'settings.json'));

  test('nothing on disk is the defaults and not a problem', () async {
    final store = SettingsStore(support: support);
    addTearDown(store.dispose);
    await store.load();
    expect(store.value, Settings.defaults);
    expect(store.problem, isNull);
  });

  test('a change is written whole and read back by the next store', () async {
    final store = SettingsStore(support: support);
    addTearDown(store.dispose);
    await store.load();
    await store.update(store.value.copyWith(engineCores: 4, engineLines: 5));
    expect(await file().readAsString(), contains('"engineCores": 4'));
    final next = SettingsStore(support: support);
    addTearDown(next.dispose);
    await next.load();
    expect(next.value.engineCores, 4);
    expect(next.value.engineLines, 5);
    expect(next.value.boardCoordinates, isTrue, reason: 'untouched');
  });

  test('a file that cannot be read says so and keeps the defaults', () async {
    await file().writeAsString('not json');
    final store = SettingsStore(support: support);
    addTearDown(store.dispose);
    await store.load();
    expect(store.value, Settings.defaults);
    expect(store.problem, contains('could not be read'));
    await store.update(store.value.copyWith(boardCoordinates: false));
    expect(store.problem, isNull, reason: 'the next change wrote a fresh file');
    expect(await file().readAsString(), contains('"boardCoordinates": false'));
  });

  test(
    'training preferences survive a restart and invalid numbers are bounded',
    () async {
      final store = SettingsStore(support: support);
      addTearDown(store.dispose);
      await store.load();
      const options = TrainingOptions(
        learnLimit: 25,
        reviewLimit: 40,
        drillLimit: 0,
        replyMillis: 1200,
        replayMistakes: false,
        shuffleDrill: true,
      );
      await store.update(store.value.copyWith(training: options));
      final next = SettingsStore(support: support);
      addTearDown(next.dispose);
      await next.load();
      expect(next.value.training, options);
      final invalid = Settings.fromJson(
        '{"training":{"learnLimit":-1,"replyMillis":99999,"drillLimit":"all"}}',
      );
      expect(invalid.training.learnLimit, 0);
      expect(invalid.training.replyMillis, 2000);
      expect(invalid.training.drillLimit, 10);
      expect(Settings.fromJson('{}').training, TrainingOptions.defaults);
    },
  );

  test('a field an older file lacks keeps its default', () {
    final read = Settings.fromJson('{"engineCores": 2, "engineLines": "x"}');
    expect(read.engineCores, 2);
    expect(read.engineLines, Settings.defaults.engineLines);
    expect(read.copyFilesIntoDocuments, isTrue);
  });

  test(
    'changes faster than the writes are all saved, the newest last',
    () async {
      final store = SettingsStore(support: support);
      addTearDown(store.dispose);
      final problems = <String>[];
      store.addListener(() {
        if (store.problem case final problem?) problems.add(problem);
      });
      // Clicks on a stepper: no caller waits for the write before its own.
      await Future.wait([
        for (var cores = 2; cores <= 16; cores++)
          store.update(store.value.copyWith(engineCores: cores)),
      ]);
      expect(problems, isEmpty, reason: 'no write was reported lost');
      expect(Settings.fromJson(await file().readAsString()).engineCores, 16);
      final next = SettingsStore(support: support);
      addTearDown(next.dispose);
      await next.load();
      expect(next.problem, isNull);
      expect(next.value, store.value);
    },
  );

  test('the same value again writes nothing', () async {
    final store = SettingsStore(support: support);
    addTearDown(store.dispose);
    var told = 0;
    store.addListener(() => told++);
    await store.update(Settings.defaults);
    expect(told, 0);
    expect(await file().exists(), isFalse);
  });
}
