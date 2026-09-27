import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/players/player.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/features/players/player_analysis.dart';
import 'package:chess_auto_prep/v2/features/players/player_games.dart';
import 'package:chess_auto_prep/v2/features/players/players.dart';
import 'package:chess_auto_prep/v2/net/recent_games.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/player_files.dart';
import 'package:chess_auto_prep/v2/storage/saved_players.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/my_games_fixture.dart';

const game =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Result "1-0"]\n[Date "2026.09.20"]\n\n1. e4 e5 2. Nf3 Nc6 1-0';
const blackGame =
    '[Event "Club"]\n[White "Bob"]\n[Black "Alex"]\n[Result "*"]\n\n1. d4 d5 *';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('exact identity, duplicate sources, side and unfinished results', () {
    final corpus = buildPlayerCorpus(
      {'alex'},
      [
        const PlayerGame(file: DocumentRef('/a.pgn'), index: 3, text: game),
        const PlayerGame(file: DocumentRef('/copy.pgn'), index: 0, text: game),
        const PlayerGame(
          file: DocumentRef('/a.pgn'),
          index: 4,
          text: blackGame,
        ),
        PlayerGame(
          file: const DocumentRef('/a.pgn'),
          index: 5,
          text: game.replaceAll('Alex', 'Alexander'),
        ),
      ],
    );
    expect(corpus.games, hasLength(2));
    expect(corpus.games.first.source.index, 3);
    expect(corpus.unmatched, 1);
    final white = corpus.positions.firstWhere((p) => p.side == Side.white);
    final black = corpus.positions.firstWhere((p) => p.side == Side.black);
    expect(white.count, 1);
    expect(white.score, 1);
    expect(black.unknown, 1);
    expect(black.score, isNull);
  });
  test('repetition counts a game at a position only once', () {
    final corpus = buildPlayerCorpus(
      {'alex'},
      [
        const PlayerGame(
          file: DocumentRef('/a.pgn'),
          index: 0,
          text:
              '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n\n1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 *',
        ),
      ],
    );
    expect(corpus.positions.first.count, 1);
    expect(corpus.positions.first.moves['g1f3'], 1);
  });
  test('pasted CSV quotes, TSV and opponent JSON preserve names', () {
    final csv = readPlayerList(
      'Name,Rating,Chess.com\n"Rivera, Alex",1900,alex_1',
    );
    expect(csv.single.name, 'Rivera, Alex');
    expect(csv.single.fields['rating'], 1900);
    final tsv = readPlayerList('Name\tUSCF ID\tLichess\nAlex\t12345678\talex');
    expect(tsv.single.text('uscf_id'), '12345678');
    expect(
      readPlayerList(
        '{"opponents":[{"name":"Alex","lookup":{"status":"pending"}}]}',
      ).single.fields['lookup'],
      {'status': 'pending'},
    );
    expect(() => readPlayerList('Alex\nBob'), throwsFormatException);
  });
  test('same display name with different US Chess IDs stays separate', () {
    expect(
      samePlayer(
        Player.create('Alex').edited({'uscf_id': '12345678'}),
        Player.create('Alex').edited({'uscf_id': '87654321'}),
      ),
      false,
    );
  });
  test(
    'roster import is idempotent and keeps notes and linked sources',
    () async {
      final store = MemoryPlayers();
      final pending = PendingWrites();
      final players = Players(store, pending);
      addTearDown(players.dispose);
      final original = Player.create('Alex').edited({
        'notes': 'Keep this',
        'pgn_files': ['/old.pgn'],
        'lookup': {'unknown': 'kept'},
      });
      await players.save(original);
      final incoming = Player.create('Alex').edited({
        'notes': 'Do not replace',
        'pgn_files': ['/new.pgn'],
        'rating': 1900,
      });
      await players.import([incoming]);
      await players.import([incoming]);
      expect(players.players, hasLength(1));
      final saved = players.players.single;
      expect(saved.id, original.id);
      expect(saved.text('notes'), 'Keep this');
      expect(saved.files, ['/old.pgn', '/new.pgn']);
      expect(saved.fields['lookup'], {'unknown': 'kept'});
      expect(await pending.settle(), isNull);
    },
  );
  test(
    'native writes preserve foreign fields, detect stale rows and recover retries',
    () async {
      final dir = await Directory.systemTemp.createTemp('players-test-');
      addTearDown(() => dir.delete(recursive: true));
      final a = PlayerFiles(dir), b = PlayerFiles(dir);
      final player = Player.create('Alex').edited({
        'lookup': {'candidate': 'alex'},
      });
      await a.savePlayer(player);
      final first = (await a.read()).players.single;
      final external = first.edited({'notes': 'Other window'});
      await b.savePlayer(external, expected: first);
      await expectLater(
        a.savePlayer(first.edited({'rating': 1800}), expected: first),
        throwsStateError,
      );
      expect((await a.read()).players.single.text('notes'), 'Other window');
      await a.savePlayer(
        external,
        expected: first,
      ); // lost acknowledgement is idempotent
      final unrelated = Player.create('Sam');
      await a.savePlayer(unrelated);
      expect((await a.read()).players, hasLength(2));
      expect((await a.read()).players.first.fields['lookup'], {
        'candidate': 'alex',
      });
    },
  );
  test(
    'removing a player removes group membership but not their PGN',
    () async {
      final store = MemoryPlayers();
      final owner = Players(store, PendingWrites());
      addTearDown(owner.dispose);
      final player = Player.create('Alex').edited({
        'pgn_files': ['/retained.pgn'],
      });
      await owner.save(player);
      await owner.saveGroup(PlayerGroup.create('Club').member(player.id));
      await owner.remove(player);
      expect(owner.players, isEmpty);
      expect(owner.groups.single.entries, isEmpty);
    },
  );
  test(
    'legacy manifest wins over flat backup, tombstones stay removed',
    () async {
      final dir = await Directory.systemTemp.createTemp('old-players-test-');
      addTearDown(() => dir.delete(recursive: true));
      final info = {'platform': 'lichess', 'username': 'Alex'};
      await File(
        '${dir.path}/lichess_alex.json',
      ).writeAsString(jsonEncode(info));
      await File('${dir.path}/lichess_alex.pgn').writeAsString(game);
      final current = Directory('${dir.path}/player-test');
      await current.create();
      await File('${current.path}/current.json').writeAsString(
        jsonEncode({'version': 1, 'deleted': true, 'player': info}),
      );
      expect(await savedPlayers(dir), isEmpty);
    },
  );
  test(
    'one malformed group leaves the directory and other groups usable',
    () async {
      final dir = await Directory.systemTemp.createTemp('player-group-test-');
      addTearDown(() => dir.delete(recursive: true));
      final store = PlayerFiles(dir);
      final player = Player.create('Alex');
      final group = PlayerGroup.create('Good group').member(player.id);
      await store.savePlayer(player);
      await store.saveGroup(group);
      await File(
        '${dir.path}/tournaments/broken.json',
      ).writeAsString('{broken');
      final read = await store.read();
      expect(read.players.single.id, player.id);
      expect(read.groups.single.id, group.id);
      expect(read.warnings.single, contains('broken.json'));
      await store.savePlayer(
        player.edited({'notes': 'Still editable'}),
        expected: player,
      );
      expect(
        (await store.read()).players.single.text('notes'),
        'Still editable',
      );
    },
  );
  test('late download cannot change another selected player', () async {
    final api = _DelayedGames();
    final store = ScriptedDocumentStore();
    final cache = GamesCache(store, folder: '/games');
    final owner = PlayerAnalysis(
      documents: store,
      archive: ScriptedGameStore(),
      cache: cache,
      sites: [api],
      pending: PendingWrites(),
      collections: '/collections',
    );
    addTearDown(owner.dispose);
    final alex = Player.create('Alex').edited({'lichess': 'alex'});
    final loading = owner.select(alex, download: true);
    await Future<void>.delayed(Duration.zero);
    await owner.select(Player.create('Other'));
    api.answer.complete(const GamesFetched([game]));
    await loading;
    expect(owner.player!.name, 'Other');
    expect(owner.corpus!.games, isEmpty);
    expect(store.documents, isEmpty);
  });
  test(
    'file revision changes refuse results and a failed read is not empty success',
    () async {
      final store = ScriptedDocumentStore();
      const ref = DocumentRef('/games.pgn');
      store.documents[ref] = Opened(game, scriptedRevision(game));
      final owner = PlayerAnalysis(
        documents: store,
        archive: ScriptedGameStore(),
        cache: GamesCache(store, folder: '/games'),
        sites: const [],
        pending: PendingWrites(),
        collections: '/collections',
      );
      addTearDown(owner.dispose);
      await owner.select(
        Player.create('Alex').edited({
          'pgn_files': [ref.path],
        }),
      );
      expect(owner.corpus!.games, hasLength(1));
      expect(await owner.currentSources(), true);
      final combined = '$game\n\n${game.replaceAll('Bob', 'Carol')}';
      store.documents[ref] = Opened(combined, scriptedRevision(combined));
      await owner.select(owner.player!);
      owner.search('Carol');
      expect(owner.positions.first.game, 1);
      expect(owner.positions.first.count, 1);
      store.documents[ref] = Opened(blackGame, scriptedRevision(blackGame));
      expect(await owner.currentSources(), false);
    },
  );
}

class _DelayedGames implements RecentGames {
  final answer = Completer<GamesFetch>();
  @override
  GameSite get site => GameSite.lichess;
  @override
  Future<GamesFetch> recent(String username, {required int max}) =>
      answer.future;
}
