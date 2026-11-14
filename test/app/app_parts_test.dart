import 'dart:io';

import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:chess_auto_prep/storage/saved_place.dart';
import 'package:chess_auto_prep/storage/settings.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/storage/update_files.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_analysis.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/scripted_engine.dart';
import '../support/scripted_releases.dart';
import '../support/scripted_tournaments.dart';
import '../support/window_fixture.dart';

/// How the app starts and is kept in step, as [AppParts] wires it: the
/// settings are read while the engine stays off, the engine follows
/// them when explicitly enabled, and what was read from the repertoire files is read
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

  test(
    'startup leaves the engine off until explicitly enabled, with saved settings',
    () async {
      await w.parts.start();
      expect(launched, isEmpty);
      expect(w.analysis.enabled, isFalse);
      expect(w.analysis.multiPv, 2);
      await w.analysis.enable();
      expect(launched, [(cores: 3, memoryMb: Settings.defaultMemoryMb)]);
      expect(w.analysis.enabled, isTrue);
      expect(w.analysis.multiPv, 2);
    },
  );

  Future<void> leftAt(Settings settings) => File(
    p.join(support.path, 'settings.json'),
  ).writeAsString(settings.toJson());

  /// Waits for the settings writes in flight, which the folder must outlive.
  Future<void> written() => w.settings.update(
    w.settings.value.copyWith(figurines: !w.settings.value.figurines),
  );

  test('a launch opens on the mode and the file the last one was left '
      'on', () async {
    await leftAt(
      Settings(
        lastPlace: SavedPlace(mode: Mode.trainer.name, path: benkoMain.path),
      ),
    );
    await w.parts.start();
    await w.parts.resumed;
    expect(w.parts.requests.mode, Mode.trainer);
    expect(w.parts.session.source, benkoMain);
    expect(w.parts.requests.backTo, isNull);
    expect(w.parts.requests.documents.tabs.tabs.map((tab) => tab.title), [
      'Trainer · Main',
    ], reason: 'the empty board the window was made with is gone');
  });

  test('a file gone since leaves the mode on an empty board, with nothing '
      'said', () async {
    await leftAt(
      Settings(
        lastPlace: SavedPlace(
          mode: Mode.repertoires.name,
          path: p.join(p.dirname(benkoMain.path), 'Gone.pgn'),
        ),
      ),
    );
    await w.parts.start();
    await w.parts.resumed;
    expect(w.parts.requests.mode, Mode.repertoires);
    expect(w.parts.session.isScratch, isTrue);
    expect(w.parts.requests.status, isNull);
  });

  group('Player analysis reopens on its player', () {
    final alex = Player({'id': 'alex', 'name': 'Alex'});

    /// The window again, over a directory holding Alex, left at [place].
    Future<void> launch(SavedPlace place) async {
      final players = MemoryPlayers();
      players.players[alex.id] = alex;
      await leftAt(Settings(lastPlace: place));
      w.dispose();
      w = WindowFixture(
        settings: SettingsStore(support: support),
        players: players,
      );
      await w.parts.start();
      await w.parts.resumed;
      await pumpEventQueue();
    }

    test(
      'a launch on Player analysis opens the player it was left on',
      () async {
        await launch(
          SavedPlace(mode: Mode.playerAnalysis.name, player: 'alex'),
        );
        expect(w.parts.requests.mode, Mode.playerAnalysis);
        expect(w.parts.players.analysis.player?.id, 'alex');
        await written();
      },
    );

    test(
      'a launch elsewhere reads no games until the mode is opened',
      () async {
        final left = SavedPlace(mode: Mode.databases.name, player: 'alex');
        await launch(left);
        expect(w.parts.players.analysis.player, isNull);
        expect(w.settings.value.lastPlace, left);
        w.parts.requests.switchTo(Mode.playerAnalysis);
        await pumpEventQueue();
        expect(w.parts.players.analysis.player?.id, 'alex');
        await written();
      },
    );

    test('a player removed since leaves the picker, and the place lets them '
        'go', () async {
      await launch(SavedPlace(mode: Mode.playerAnalysis.name, player: 'gone'));
      expect(w.parts.requests.mode, Mode.playerAnalysis);
      expect(w.parts.players.analysis.player, isNull);
      expect(
        w.settings.value.lastPlace,
        SavedPlace(mode: Mode.playerAnalysis.name),
      );
      await written();
    });

    test('a player chosen is kept as the user moves to another mode', () async {
      await launch(SavedPlace(mode: Mode.databases.name));
      w.parts.players.choose(alex);
      await pumpEventQueue();
      w.parts.requests.switchTo(Mode.databases);
      expect(
        w.settings.value.lastPlace,
        SavedPlace(mode: Mode.databases.name, player: 'alex'),
      );
      await written();
    });
  });

  test('the place is kept as the user moves between files and modes', () async {
    await w.parts.start();
    await w.parts.resumed;
    await w.parts.requests.open(kidMain);
    expect(
      w.settings.value.lastPlace,
      SavedPlace(mode: Mode.repertoires.name, path: kidMain.path),
    );
    w.parts.requests.switchTo(Mode.databases);
    expect(w.settings.value.lastPlace, SavedPlace(mode: Mode.databases.name));
    await written();
  });

  test('the engine comes back as the user left its switch, not as a mode '
      'left it', () async {
    await leftAt(const Settings(engineOn: true));
    await w.parts.start();
    await pumpEventQueue();
    expect(w.analysis.enabled, isTrue);
    await w.analysis.disable();
    expect(w.settings.value.engineOn, isTrue, reason: 'a mode hid an answer');
    await w.analysis.turn(false);
    expect(w.settings.value.engineOn, isFalse);
    await w.analysis.turn(true);
    expect(w.settings.value.engineOn, isTrue);
    await written();
  });

  test('unreadable settings start the app on the defaults', () async {
    final file = File(p.join(support.path, 'settings.json'));
    await file.writeAsString('not json');
    await w.parts.start();
    expect(launched, isEmpty);
    expect(w.analysis.enabled, isFalse);
    await w.analysis.enable();
    expect(launched, [
      (
        cores: Settings.defaults.coresOn(w.parts.env.coresAvailable),
        memoryMb: Settings.defaultMemoryMb,
      ),
    ]);
    expect(w.settings.problem, isNull);
  });

  test('new cores or a new table start another engine; more lines do '
      'not', () async {
    await w.parts.start();
    await w.analysis.enable();
    await w.settings.update(w.settings.value.copyWith(engineLines: 4));
    await pumpEventQueue();
    expect(launched, hasLength(1), reason: 'the same engine is asked');
    expect(w.analysis.multiPv, 4);

    await w.settings.update(w.settings.value.copyWith(engineCores: 4));
    await pumpEventQueue();
    expect(launched.last, (cores: 4, memoryMb: Settings.defaultMemoryMb));

    await w.settings.update(w.settings.value.copyWith(engineMemoryMb: 512));
    await pumpEventQueue();
    expect(launched.last, (cores: 4, memoryMb: 512));
    expect(launched, hasLength(3));
  });

  test('changing settings while off does not launch the engine', () async {
    await w.parts.start();
    await w.settings.update(
      w.settings.value.copyWith(engineCores: 4, engineLines: 3),
    );
    await pumpEventQueue();
    expect(launched, isEmpty);
    expect(w.analysis.enabled, isFalse);
    await w.analysis.enable();
    expect(launched, [(cores: 4, memoryMb: Settings.defaultMemoryMb)]);
    expect(w.analysis.multiPv, 3);
  });

  test('a second start reads nothing again', () async {
    await w.parts.start();
    await leftAt(const Settings(engineLines: 4));
    await w.parts.start();
    expect(w.analysis.multiPv, 2);
  });

  test(
    'with nothing left to write, the window closes without a word',
    () async {
      await w.parts.start();
      expect(await w.parts.exit.mayClose(), isTrue);
      expect(w.question.asked, isEmpty);
    },
  );

  group('an update that did not finish installing', () {
    Future<WindowFixture> started({required bool failed}) async {
      final updates = Directory(p.join(support.path, 'updates'))..createSync();
      if (failed) {
        File(
          p.join(updates.path, 'last-error.txt'),
        ).writeAsStringSync('Update installation failed (exit 1).');
      }
      final window = WindowFixture(
        updates: (
          releases: ScriptedReleases(),
          folder: UpdateFolder(updates),
          installer: portableInstaller(support),
          version: () async => '1.16.1',
          automatic: false,
          openPage: (_) async => true,
          showFolder: (_) {},
        ),
      );
      addTearDown(window.dispose);
      await window.parts.start();
      for (var i = 0; i < 100 && window.requests.status == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return window;
    }

    test('is said once the window starts', () async {
      final window = await started(failed: true);
      expect(window.requests.status, contains('did not finish'));
    });

    test('is not said when there was none', () async {
      final window = await started(failed: false);
      expect(window.requests.status, isNull);
    });
  });

  test('the engine tournaments are wired only where the environment can '
      'both keep and run them', () async {
    final registry = ScriptedTournaments();
    addTearDown(registry.dispose);
    final both = WindowFixture(
      tournaments: registry,
      launchTournament: (_, _) async => const StartFailed('not launched'),
    );
    addTearDown(both.dispose);
    expect(both.parts.tournaments, isNotNull);
    final keepOnly = WindowFixture(tournaments: registry);
    addTearDown(keepOnly.dispose);
    expect(keepOnly.parts.tournaments, isNull);
    expect(w.parts.tournaments, isNull);
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

  group('the analysis engine', () {
    late WindowFixture fixture;
    late ScriptedTournaments registry;
    late List<String> started;
    late EngineStart Function(TournamentEngine engine) registered;

    final komodo = TournamentEngine({
      'id': 'engine-1',
      'name': 'Komodo',
      'executablePath': '/engines/komodo',
      'options': {'Contempt': '0'},
      'threads': 1,
      'hashMb': 16,
    });

    setUp(() {
      registry = ScriptedTournaments()..registry = [komodo];
      started = [];
      registered = (_) => Started(ScriptedEngine());
      fixture = WindowFixture(
        coresAvailable: 8,
        tournaments: registry,
        launchEngine: ({required cores, required memoryMb}) async {
          started.add('stockfish $cores $memoryMb');
          return Started(ScriptedEngine());
        },
        launchRegisteredEngine:
            (engine, {required cores, required memoryMb}) async {
              started.add('${engine.name} $cores $memoryMb');
              return registered(engine);
            },
      );
    });

    tearDown(() async {
      fixture.dispose();
      await registry.dispose();
    });

    EngineState state() => fixture.analysis.state;

    test('is the bundled Stockfish on half of the machine until another is '
        'chosen', () async {
      await fixture.parts.start();
      await fixture.analysis.enable();
      expect(started, ['stockfish 4 ${Settings.defaultMemoryMb}']);
      expect((state() as EngineRunning).notice, isNull);
    });

    test('a registered engine chosen runs with the same cores and table, '
        'and choosing again starts the other one', () async {
      await fixture.parts.start();
      await fixture.settings.update(
        fixture.settings.value.copyWith(
          analysisEngine: 'engine-1',
          engineCores: 6,
        ),
      );
      await fixture.analysis.enable();
      expect(started, ['Komodo 6 ${Settings.defaultMemoryMb}']);
      expect((state() as EngineRunning).notice, isNull);

      await fixture.settings.update(
        fixture.settings.value.copyWith(analysisEngine: Settings.builtInEngine),
      );
      await pumpEventQueue();
      expect(started.last, 'stockfish 6 ${Settings.defaultMemoryMb}');
      expect(fixture.analysis.enabled, isTrue);
    });

    test(
      'one that does not start gives way to Stockfish, which says why',
      () async {
        registered = (_) => const StartFailed('komodo is not executable.');
        await fixture.parts.start();
        await fixture.settings.update(
          fixture.settings.value.copyWith(analysisEngine: 'engine-1'),
        );
        await fixture.analysis.enable();
        expect(started, [
          'Komodo 4 ${Settings.defaultMemoryMb}',
          'stockfish 4 ${Settings.defaultMemoryMb}',
        ]);
        final running = state() as EngineRunning;
        expect(
          running.notice,
          'Komodo did not start: komodo is not executable.',
        );
        expect(fixture.analysis.enabled, isTrue, reason: 'never locked out');
      },
    );

    test('one no longer registered gives way to Stockfish too', () async {
      registry.registry = [];
      await fixture.parts.start();
      await fixture.settings.update(
        fixture.settings.value.copyWith(analysisEngine: 'engine-1'),
      );
      await fixture.analysis.enable();
      expect(started, ['stockfish 4 ${Settings.defaultMemoryMb}']);
      expect(
        (state() as EngineRunning).notice,
        'The chosen engine is no longer registered',
      );
    });

    test('with neither engine starting, the pane says both', () async {
      registered = (_) => const StartFailed('komodo is not there.');
      final broken = WindowFixture(
        coresAvailable: 8,
        tournaments: registry,
        launchRegisteredEngine:
            (engine, {required cores, required memoryMb}) async =>
                registered(engine),
      );
      addTearDown(broken.dispose);
      await broken.parts.start();
      await broken.settings.update(
        broken.settings.value.copyWith(analysisEngine: 'engine-1'),
      );
      await broken.analysis.enable();
      final failed = broken.analysis.state as EngineFailed;
      expect(failed.reason, startsWith('Komodo did not start'));
      expect(failed.reason, endsWith('no engine in this test'));
    });
  });
}
