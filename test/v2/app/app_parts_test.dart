import 'dart:io';

import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/scripted_engine.dart';
import '../support/window_fixture.dart';

/// How the app starts and is kept in step, as [AppParts] wires it: the
/// settings are read before the engine starts on them, the engine follows
/// them from then on, and what was read from the repertoire files is read
/// again only when the files are listed anew.
void main() {
  late Directory support;
  late List<({int cores, int memoryMb})> launched;
  late WindowFixture w;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('app_parts_test');
    await File(
      p.join(support.path, 'settings.json'),
    ).writeAsString(const Settings(engineCores: 3, engineLines: 2).toJson());
    launched = [];
    w = WindowFixture(
      settings: SettingsStore(support: support),
      launchEngine: ({required cores, required memoryMb}) async {
        launched.add((cores: cores, memoryMb: memoryMb));
        return Started(ScriptedEngine());
      },
    );
  });

  tearDown(() async {
    w.dispose();
    await support.delete(recursive: true);
  });

  test('the engine starts once, on the cores and lines the settings file '
      'says', () async {
    await w.parts.start();
    expect(launched, [(cores: 3, memoryMb: 128)]);
    expect(w.analysis.enabled, isTrue);
    expect(w.analysis.multiPv, 2);
  });

  test('unreadable settings start the app on the defaults', () async {
    final file = File(p.join(support.path, 'settings.json'));
    await file.writeAsString('not json');
    await w.parts.start();
    expect(launched, [(cores: Settings.defaults.engineCores, memoryMb: 128)]);
    expect(w.settings.problem, isNull);
  });

  test('new cores or a new table start another engine; more lines do '
      'not', () async {
    await w.parts.start();
    await w.settings.update(w.settings.value.copyWith(engineLines: 4));
    await pumpEventQueue();
    expect(launched, hasLength(1), reason: 'the same engine is asked');
    expect(w.analysis.multiPv, 4);

    await w.settings.update(w.settings.value.copyWith(engineCores: 4));
    await pumpEventQueue();
    expect(launched.last, (cores: 4, memoryMb: 128));

    await w.settings.update(w.settings.value.copyWith(engineMemoryMb: 256));
    await pumpEventQueue();
    expect(launched.last, (cores: 4, memoryMb: 256));
    expect(launched, hasLength(3));
  });

  test('a window taken down while the settings are read starts no '
      'engine', () async {
    final starting = w.parts.start();
    w.parts.dispose();
    await starting;
    await pumpEventQueue();
    expect(launched, isEmpty);
  });

  test('a search typed into the library reads no repertoire file again; a '
      'new listing does', () async {
    w.accounts.accounts[GameSite.lichess] = const Account('me');
    await w.parts.books.load();
    await w.library.refresh();
    w.tree.watch();
    w.book.watch();
    await pumpEventQueue();
    final listed = w.chapterFiles.listings;

    w.library.search('K');
    await pumpEventQueue();
    expect(w.chapterFiles.listings, listed, reason: 'no file changed');

    await w.library.refresh();
    await pumpEventQueue();
    expect(
      w.chapterFiles.listings,
      greaterThan(listed + 1),
      reason: 'the tree and the book read the files again',
    );
  });
}
