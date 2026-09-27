import 'package:chess_auto_prep/v2/chess/training/training_options.dart';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
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

  Directory quarantine() =>
      Directory(p.join(support.path, 'recovery-quarantine'));

  Future<List<String>> quarantined() async => [
    await for (final entry in quarantine().list(recursive: true))
      if (entry is File) await entry.readAsString(),
  ];

  test(
    'unreadable settings are moved aside and the app starts on defaults',
    () async {
      await file().writeAsString('not json');
      final store = SettingsStore(support: support);
      addTearDown(store.dispose);
      await store.load();
      expect(store.value, Settings.defaults);
      expect(store.problem, isNull);
      expect(await quarantined(), ['not json'], reason: 'kept, not deleted');
      await store.update(store.value.copyWith(engineCores: 3));
      expect(Settings.fromJson(await file().readAsString()).engineCores, 3);
    },
  );

  for (final (name, bytes) in [
    ('bad UTF-8', [0xff, 0xfe, 0x00]),
    ('a JSON list', utf8.encode('[1, 2]')),
  ]) {
    test('$name is moved aside, not a blocked start', () async {
      await file().writeAsBytes(bytes);
      final store = SettingsStore(support: support);
      addTearDown(store.dispose);
      await store.load();
      expect(store.value, Settings.defaults);
      expect(await file().exists(), isFalse);
      expect(await quarantine().exists(), isTrue);
    });
  }

  test('a directory at the settings path is moved aside too', () async {
    await Directory(file().path).create();
    final store = SettingsStore(support: support);
    addTearDown(store.dispose);
    await store.load();
    expect(store.value, Settings.defaults);
    await store.update(store.value.copyWith(engineCores: 2));
    expect(store.problem, isNull);
    expect(Settings.fromJson(await file().readAsString()).engineCores, 2);
  });

  test('a symlinked settings file is followed and stays a link', () async {
    final dotfiles = await Directory.systemTemp.createTemp('v2-dotfiles-');
    addTearDown(() => dotfiles.delete(recursive: true));
    final target = File(p.join(dotfiles.path, 'settings.json'));
    await target.writeAsString(const Settings(engineCores: 5).toJson());
    await Link(file().path).create(target.path);
    final store = SettingsStore(support: support);
    addTearDown(store.dispose);
    await store.load();
    expect(store.value.engineCores, 5);
    await store.update(store.value.copyWith(engineCores: 7));
    expect(store.problem, isNull);
    expect(await FileSystemEntity.isLink(file().path), isTrue);
    expect(Settings.fromJson(await target.readAsString()).engineCores, 7);
  });

  test('a staged copy left by a crash does not block saving', () async {
    final store = SettingsStore(support: support);
    addTearDown(store.dispose);
    await store.load();
    await File(temporaryPathFor(file().path)).writeAsString('half a write');
    await store.update(store.value.copyWith(engineCores: 4));
    expect(store.problem, isNull);
    expect(Settings.fromJson(await file().readAsString()).engineCores, 4);
    await store.update(store.value.copyWith(engineCores: 6));
    expect(Settings.fromJson(await file().readAsString()).engineCores, 6);
  });

  test('a failed write is reported and the next change saves', () async {
    var fail = true;
    final store = SettingsStore(
      support: support,
      publish: (path, bytes) async {
        if (fail) throw const FileSystemException('disk full');
        await replaceFile(path, bytes);
      },
    );
    addTearDown(store.dispose);
    await store.load();
    await store.update(store.value.copyWith(engineCores: 4));
    expect(store.value.engineCores, 4, reason: 'the choice stays on screen');
    expect(store.problem, contains('could not be saved'));
    fail = false;
    await store.update(store.value.copyWith(engineLines: 5));
    expect(store.problem, isNull);
    final saved = Settings.fromJson(await file().readAsString());
    expect((saved.engineCores, saved.engineLines), (4, 5));
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
        replyMillis: 1200,
        replayMistakes: false,
      );
      await store.update(store.value.copyWith(training: options));
      final next = SettingsStore(support: support);
      addTearDown(next.dispose);
      await next.load();
      expect(next.value.training, options);
      final invalid = Settings.fromJson(
        '{"training":{"learnLimit":-1,"replyMillis":99999,"drillLimit":10,"shuffleDrill":true}}',
      );
      expect(invalid.training.learnLimit, 0);
      expect(invalid.training.replyMillis, 2000);
      expect(invalid.training.reviewLimit, 0);
      expect(invalid.training.toJson(), isNot(contains('drillLimit')));
      expect(invalid.training.toJson(), isNot(contains('shuffleDrill')));
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
      await store.load();
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
