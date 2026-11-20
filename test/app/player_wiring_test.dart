// The players' wiring: the analysis follows its player's record but not
// its removal; a download keeps the range first and runs only once it is
// kept; studies are linked beside those already linked and opened at the
// chapter named; a group study that could not be made is not linked; and
// a prep sheet is copied, or saved where the export put it, or the reason
// it was not is said.
import 'dart:async';

import 'package:chess_auto_prep/chess/players/download_range.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/players/saved_games.dart';
import 'package:chess_auto_prep/net/recent_games.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_engine.dart';
import '../support/scripted_store.dart';
import '../support/study_fixture.dart';
import '../support/window_fixture.dart';

const _games =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.20"]\n'
    '[Result "1-0"]\n\n1. e4 e5 1-0\n';

final class _DelayedSite implements RecentGames {
  @override
  GameSite get site => GameSite.lichess;
  final reply = Completer<GamesFetch>();

  @override
  Future<GamesFetch> recent(String username, {required int max}) =>
      reply.future;
}

/// The directory in memory, whose next player save can be made to fail.
final class _FlakyPlayers implements PlayerStore {
  final _inner = MemoryPlayers();
  bool failNextSave = false;
  @override
  Future<PlayerDirectory> read() => _inner.read();
  @override
  Future<void> savePlayer(Player player, {Player? expected}) async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('disk full');
    }
    await _inner.savePlayer(player, expected: expected);
  }

  @override
  Future<void> saveGroup(PlayerGroup group, {PlayerGroup? expected}) =>
      _inner.saveGroup(group, expected: expected);
  @override
  Future<void> removePlayer(Player player) => _inner.removePlayer(player);
  @override
  Future<void> removeGroup(PlayerGroup group) => _inner.removeGroup(group);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WindowFixture w;
  late ScriptedEngine engine;
  late List<RecentGames> sites;
  late _FlakyPlayers store;
  late Player player;
  late String? exported;
  Object? exportFails;

  setUp(() async {
    exported = '/Documents/Club.md';
    exportFails = null;
    store = _FlakyPlayers();
    engine = ScriptedEngine();
    sites = [];
    w = WindowFixture(
      players: store,
      gameSites: sites,
      launchEngine: ({required cores, required memoryMb}) async =>
          Started(engine),
      exportText: (name, text) async {
        if (exportFails case final thrown?) throw thrown;
        return exported;
      },
    );
    const ref = DocumentRef('/collections/player.pgn');
    w.store.documents[ref] = Opened(_games, scriptedRevision(_games));
    player = Player.create('Alex').edited({
      'pgn_files': [ref.path],
      'lichess': 'alex',
    });
    await w.parts.players.directory.save(player);
  });
  tearDown(() => w.dispose());

  Player stored() => w.parts.players.directory.players.single;

  test('the analysis keeps its player when the record is removed', () async {
    final players = w.parts.players;
    await players.analysis.select(stored());
    await players.directory.remove(stored());
    await pumpEventQueue();
    expect(players.directory.players, isEmpty);
    expect(players.analysis.player?.name, 'Alex');
  });

  group('a download', () {
    /// Every status the analysis shows from now on.
    List<String?> statuses() {
      final said = <String?>[];
      final analysis = w.parts.players.analysis;
      void heard() => said.add(analysis.status);
      analysis.addListener(heard);
      addTearDown(() => analysis.removeListener(heard));
      return said;
    }

    test('keeps the range on the player, then downloads', () async {
      final players = w.parts.players;
      await players.analysis.select(stored());
      final said = statuses();
      await players.download(const PlayerDownloadRange(months: 3));
      expect(stored().fields['download'], isNotNull);
      expect(said, contains(startsWith('Downloading')));
    });

    test(
      'submitted from an open dialog keeps its range during deletion',
      () async {
        final players = w.parts.players;
        final alex = stored();
        final account = alex.accounts.single;
        final ref = w.gamesCache.refFor(account.site, account.username);
        await w.store.create(ref, _games);
        await players.analysis.select(alex);
        await players.saved.refresh();
        final confirmed = (await players.saved.current(alex))!;
        final gate = w.store.readEarly = Completer<void>();
        final deleting = players.deleteGames(alex, confirmed);
        await pumpEventQueue();
        expect(w.store.readEarly, isNull);

        const range = PlayerDownloadRange(months: 7);
        final downloading = players.download(range);
        await pumpEventQueue();
        expect(stored().fields['download'], range.json);

        gate.complete();
        expect(await deleting, isTrue);
        await downloading;
      },
    );

    for (final refused in [false, true]) {
      test(
        'a reply during deletion is kept only if it fails (refused=$refused)',
        () async {
          final players = w.parts.players;
          final alex = stored();
          final ref = w.gamesCache.refFor(GameSite.lichess, 'alex');
          await w.store.create(ref, _games);
          await players.analysis.select(alex);
          await players.saved.refresh();
          final confirmed = (await players.saved.current(alex))!;
          final site = _DelayedSite();
          sites.add(site);
          final download = players.analysis.select(alex, download: true);
          final gate = w.store.readEarly = Completer<void>();
          if (refused) w.store.deletes.add(const IoFailure('read-only folder'));
          final deleting = players.deleteGames(alex, confirmed);
          await pumpEventQueue();
          expect(w.store.readEarly, isNull);
          final fresh = _games.replaceAll('Bob', 'Bea');
          site.reply.complete(
            GamesFetched([fresh], unread: const ['earlier games']),
          );
          await pumpEventQueue();
          expect((w.store.documents[ref]! as Opened).text, _games);

          gate.complete();
          expect(await deleting, !refused);
          await download;
          if (refused) {
            expect((w.store.documents[ref]! as Opened).text, contains('Bea'));
          } else {
            expect(w.store.deleted[ref], _games);
            expect(w.store.documents[ref], isNull);
          }
        },
      );
    }

    test('whose range was not kept does not run', () async {
      final players = w.parts.players;
      await players.analysis.select(stored());
      store.failNextSave = true;
      final said = statuses();
      await players.download(const PlayerDownloadRange(months: 3));
      expect(said, isNot(contains(startsWith('Downloading'))));
    });
  });

  test(
    'deleting saved games during analysis leaves no partial report',
    () async {
      final players = w.parts.players;
      final alex = stored();
      final account = alex.accounts.single;
      final download = w.gamesCache.refFor(account.site, account.username);
      await w.store.create(download, _games);
      await players.analysis.select(alex);

      final hunt = players.hunt;
      final running = hunt.start();
      await pumpEventQueue();
      engine.current
        ..emit(line(depth: hunt.depth, pv: ['e2e4']))
        ..end();
      await pumpEventQueue();
      expect(hunt.done, 1);
      expect(hunt.running, isTrue);

      players.showDirectory();
      await players.saved.refresh();
      final confirmed = (await players.saved.current(alex))!;
      expect(confirmed.deletable, 1);
      expect(await players.deleteGames(alex, confirmed), isTrue);
      await running;
      await players.analysis.pending.settle();

      // Restoring the same PGN makes the original report eligible to load again.
      await w.store.create(download, w.store.deleted[download]!);
      await players.analysis.select(alex);
      await pumpEventQueue();
      expect(hunt.done, 0);
    },
  );

  test('a failed discard leaves the running hunt on its position', () async {
    final players = w.parts.players;
    final alex = stored();
    final account = alex.accounts.single;
    final ref = w.gamesCache.refFor(account.site, account.username);
    await w.store.create(ref, _games);
    await players.analysis.select(alex);
    await players.saved.refresh();
    final confirmed = (await players.saved.current(alex))!;
    final running = players.hunt.start();
    await pumpEventQueue();
    final search = engine.current;
    w.store.deletes.add(const IoFailure('read-only folder'));

    expect(await players.deleteGames(alex, confirmed), isFalse);
    expect(w.store.documents[ref], isA<Opened>());
    expect(players.hunt.running, isTrue);
    expect(search.stopped, isFalse);
    search
      ..emit(line(depth: players.hunt.depth, pv: ['e2e4']))
      ..end();
    await pumpEventQueue();
    expect(players.hunt.done, 1);
    players.hunt.stop();
    await running;
  });

  group('a linked study', () {
    test('is linked beside the ones already linked', () async {
      final players = w.parts.players;
      for (final name in ['Endgames', 'Openings']) {
        w.viewerPicker.answer = '/Documents/studies/$name.pgn';
        await players.linkStudy(stored());
      }
      expect(
        [
          for (final link in stored().fields['studies']! as List)
            (link as Map)['path'],
        ],
        ['/Documents/studies/Endgames.pgn', '/Documents/studies/Openings.pgn'],
      );
    });

    test('opens at the chapter named', () async {
      final ref = studyRef('Endgames');
      w.store.documents[ref] = Opened(
        twoChapterStudy,
        scriptedRevision(twoChapterStudy),
      );
      await w.parts.players.openLinkedStudy(ref.path, 'Pawn endings');
      expect(w.session.source?.path, ref.path);
      expect(w.session.game, 1);
    });
  });

  test('a group study that could not be made is not linked', () async {
    final directory = w.parts.players.directory;
    final group = PlayerGroup.create('Club');
    await directory.saveGroup(group);
    w.store.creates.add(const IoFailure('disk full'));
    await w.parts.players.openGroupStudy(directory.groups.single);
    expect(directory.groups.single.fields['study'], isNull);
    expect(w.requests.statusIsProblem, isTrue);
  });

  group("a group's prep sheet", () {
    final group = PlayerGroup.create('Club');

    test('copied, says so as news, not a problem', () async {
      await w.parts.players.exportGroup(group, copy: true);
      expect(w.requests.status, 'Prep sheet copied, including saved lines.');
      expect(w.requests.statusIsProblem, isFalse);
    });

    test('exported, says where it went', () async {
      await w.parts.players.exportGroup(group);
      expect(w.requests.status, 'Saved /Documents/Club.md');
    });

    test('not saved anywhere, says nothing', () async {
      exported = null;
      w.requests.say('Earlier');
      await w.parts.players.exportGroup(group);
      expect(w.requests.status, 'Earlier');
    });

    test('that could not be written, says why', () async {
      exportFails = StateError('disk full');
      await w.parts.players.exportGroup(group);
      expect(w.requests.status, startsWith('Could not export the prep sheet'));
    });
  });
}
