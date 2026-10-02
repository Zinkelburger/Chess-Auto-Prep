import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/features/players/player_analysis.dart';
import 'package:chess_auto_prep/features/players/player_games.dart';
import 'package:chess_auto_prep/features/players/players.dart';
import 'package:chess_auto_prep/net/recent_games.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/game_store.dart';
import 'package:chess_auto_prep/storage/my_games_files.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:chess_auto_prep/storage/saved_players.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
  test('filtered statistics count results from either player side without '
      'changing the corpus', () {
    final store = ScriptedDocumentStore();
    final owner = PlayerAnalysis(
      documents: store,
      archive: ScriptedGameStore(),
      cache: GamesCache(store, folder: '/games'),
      sites: const [],
      pending: PendingWrites(),
      archiveCopies: '/archive',
    );
    addTearDown(owner.dispose);
    final sources = <PlayerGame>[];
    for (final side in Side.values) {
      for (final (opponent, result) in [
        ('Keep win', side == Side.white ? '1-0' : '0-1'),
        ('Keep draw', '1/2-1/2'),
        ('Keep unfinished', '*'),
        ('Drop loss', side == Side.white ? '0-1' : '1-0'),
      ]) {
        final white = side == Side.white ? 'Alex' : opponent;
        final black = side == Side.black ? 'Alex' : opponent;
        sources.add(
          PlayerGame(
            file: const DocumentRef('/games.pgn'),
            index: sources.length,
            text:
                '[White "$white"]\n[Black "$black"]\n[Result "$result"]\n\n'
                '1. e4 e5 2. Nf3 Nc6 $result',
          ),
        );
      }
    }
    final corpus = owner.corpus = buildPlayerCorpus({'alex'}, sources);
    owner.minPly = 0;
    for (final side in Side.values) {
      owner.setSide(side);
      owner.search('Keep');
      expect(owner.gameIndexes, hasLength(3));
      for (final position in owner.positions) {
        expect(position.games, owner.gameIndexes.toSet());
        expect(
          (position.wins, position.draws, position.losses, position.unknown),
          (1, 1, 0, 1),
        );
        expect(position.score, 0.75);
      }
      owner.minGames = 4;
      expect(owner.positions, isEmpty);
      owner.search('');
      expect(owner.positions, isNotEmpty);
      expect(owner.positions.first.score, 0.5);
      owner.minGames = 1;
    }
    for (final position in corpus.positions) {
      expect(position.count, 4);
      expect(
        (position.wins, position.draws, position.losses, position.unknown),
        (1, 1, 1, 1),
      );
    }
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
  test('the MCP opponents_export file pastes as players', () {
    // The shape tools/mcp/chess_prep/opponents.py writes.
    final players = readPlayerList('''{
      "format": "chess-auto-prep/opponents@1",
      "event": "Spring Open 2026",
      "rounds": 5,
      "opponents": [
        {"name": "Jane Doe", "chesscom": "janed", "lichess": "jd_li",
         "rating": 1850, "title": "FM", "uscf_id": "12345678",
         "pairing_prob": 0.42, "pairing_prob_white": 0.2,
         "pairing_prob_black": 0.22, "most_likely_round": 2,
         "identity": {"confidence": "high", "source": "uscf"}},
        {"name": "Sam Roe", "lichess": "samr"}
      ]
    }''');
    expect(players.map((p) => p.name), ['Jane Doe', 'Sam Roe']);
    expect(players.first.accounts.map((a) => (a.site, a.username)), [
      (GameSite.lichess, 'jd_li'),
      (GameSite.chesscom, 'janed'),
    ]);
    expect(players.first.fields['rating'], 1850);
    expect(players.first.text('uscf_id'), '12345678');
    expect(players.first.fields['pairing_prob'], 0.42);
    expect(players.last.accounts.single.username, 'samr');
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
        throwsA(isA<PlayerConflict>()),
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
  test('one unreadable flat json does not hide other saved players', () async {
    final dir = await Directory.systemTemp.createTemp('old-players-test-');
    addTearDown(() => dir.delete(recursive: true));
    final info = {'platform': 'lichess', 'username': 'Alex', 'accounts': 3};
    await File('${dir.path}/lichess_alex.json').writeAsString(jsonEncode(info));
    await File('${dir.path}/lichess_alex.pgn').writeAsString(game);
    await File(
      '${dir.path}/lichess_alex_white_analysis.json',
    ).writeAsString('[broken');
    await File('${dir.path}/bad.json').writeAsBytes([0xff, 0xfe]);
    final broken = Directory('${dir.path}/player-broken');
    await broken.create();
    await File('${broken.path}/current.json').writeAsString('[broken');
    final hash = 'a' * 64;
    await Directory('${dir.path}/player-nameless').create();
    await File('${dir.path}/player-nameless/current.json').writeAsString(
      jsonEncode({
        'version': 1,
        'revision': '1-$hash',
        'player': {'platform': 'lichess'},
      }),
    );
    final sam = {'platform': 'lichess', 'username': 'Sam'};
    await File('${dir.path}/lichess_sam.json').writeAsString(jsonEncode(sam));
    await File('${dir.path}/lichess_sam.pgn').writeAsString(game);
    await Directory('${dir.path}/player-sam').create();
    await File(
      '${dir.path}/player-sam/current.json',
    ).writeAsString(jsonEncode({'version': 2, 'player': sam}));
    final players = await savedPlayers(dir);
    expect(players.single.name, 'Alex');
    expect(players.single.files, ['${dir.path}/lichess_alex.pgn']);
  });
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
      archiveCopies: '/archive',
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
        archiveCopies: '/archive',
      );
      addTearDown(owner.dispose);
      await owner.select(
        Player.create('Alex').edited({
          'pgn_files': [ref.path],
        }),
      );
      expect(owner.corpus!.games, hasLength(1));
      expect(await owner.currentSources(), true);
      final corpus = owner.corpus;
      final fingerprint = owner.fingerprint;
      final revision = owner.revisionOf(ref);
      store.documents[ref] = const Unreadable('permission denied');
      await owner.select(owner.player!);
      expect(owner.error, 'Could not read this player’s games.');
      expect(owner.corpus, same(corpus));
      expect(owner.fingerprint, fingerprint);
      expect(owner.revisionOf(ref), revision);
      expect(await owner.currentSources(), isFalse);
      store.documents[ref] = Opened(game, scriptedRevision(game));
      await owner.retry();
      expect(owner.error, isNull);
      expect(await owner.currentSources(), isTrue);
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
  test(
    'older saved games that cannot be copied are a warning, not a failure',
    () async {
      final store = ScriptedDocumentStore();
      const ref = DocumentRef('/games.pgn');
      store.documents[ref] = Opened(game, scriptedRevision(game));
      store.creates.add(const IoFailure('disk full'));
      final archive = ScriptedGameStore()
        ..answer = StoredGamesFound([
          StoredGame(
            collection: 'analysis:old',
            key: 'a',
            pgn: game.replaceAll('Bob', 'Carol'),
          ),
        ]);
      final owner = PlayerAnalysis(
        documents: store,
        archive: archive,
        cache: GamesCache(store, folder: '/games'),
        sites: const [],
        pending: PendingWrites(),
        archiveCopies: '/archive',
      );
      addTearDown(owner.dispose);
      await owner.select(
        Player.create('Alex').edited({
          'pgn_files': [ref.path],
          'game_sets': ['old'],
        }),
      );
      expect(owner.error, isNull);
      expect(owner.corpus!.games.single.source.file, ref);
      expect(
        owner.warnings,
        contains(startsWith('Older saved games could not be shown.')),
      );
    },
  );
  test(
    'older saved games are copied once per player, never into collections',
    () async {
      final store = ScriptedDocumentStore();
      const first = StoredGame(collection: 'analysis:old', key: 'a', pgn: game);
      final archive = ScriptedGameStore()..answer = StoredGamesFound([first]);
      final owner = PlayerAnalysis(
        documents: store,
        archive: archive,
        cache: GamesCache(store, folder: '/games'),
        sites: const [],
        pending: PendingWrites(),
        archiveCopies: '/archive',
      );
      addTearDown(owner.dispose);
      final alex = Player.create('Alex').edited({
        'game_sets': ['old'],
      });
      await owner.select(alex);
      expect(owner.corpus!.games, hasLength(1));
      archive.answer = StoredGamesFound([
        first,
        StoredGame(
          collection: 'analysis:old',
          key: 'b',
          pgn: game.replaceAll('Bob', 'Carol'),
        ),
      ]);
      await owner.select(alex);
      expect(owner.error, isNull);
      expect(owner.corpus!.games, hasLength(2));
      // The one file ever written is the player's copy, beside no collection.
      final copies = store.documents.keys.toList();
      expect(copies.map((r) => p.dirname(r.path)), ['/archive']);
      expect(
        splitChapterText(
          (store.documents[copies.single]! as Opened).text,
        ).games,
        hasLength(2),
      );
      expect(owner.corpus!.games.map((g) => g.source.file).toSet(), {
        copies.single,
      });
      // Nothing new in the archive writes nothing.
      final saves = store.requestedSaves.length;
      final held = store.documents[copies.single];
      await owner.select(alex);
      expect(store.requestedSaves, hasLength(saves));
      expect(store.documents[copies.single], same(held));
    },
  );
  test('what the user keeps in the archive copy is never replaced', () async {
    final store = ScriptedDocumentStore();
    final online = game.replaceFirst(
      '[Event "Club"]',
      '[Event "Club"]\n[Site "https://lichess.org/abcdefgh"]',
    );
    final archive = ScriptedGameStore()
      ..answer = StoredGamesFound([
        StoredGame(collection: 'analysis:old', key: 'a', pgn: online),
      ]);
    final owner = PlayerAnalysis(
      documents: store,
      archive: archive,
      cache: GamesCache(store, folder: '/games'),
      sites: const [],
      pending: PendingWrites(),
      archiveCopies: '/archive',
    );
    addTearDown(owner.dispose);
    final alex = Player.create('Alex').edited({
      'game_sets': ['old'],
    });
    await owner.select(alex);
    final copy = store.documents.keys.single;
    final edited = '${online.replaceFirst('2. Nf3', '2. Nf3 {Kept}')}\n';
    store.documents[copy] = Opened(edited, scriptedRevision(edited));
    await owner.select(alex);
    expect(owner.error, isNull);
    expect((store.documents[copy]! as Opened).text, edited);
    expect(store.requestedSaves, isEmpty);
    expect(owner.corpus!.games.single.source.file, copy);
  });
  test('Player analysis tells correspondence from Other and classes a '
      'Lichess game by Lichess\'s limits', () async {
    final store = ScriptedDocumentStore();
    const ref = DocumentRef('/games.pgn');
    final text = [
      timed('1/86400', 11),
      timed(null, 12),
      timed('180+0', 13),
      timed('480', 14).replaceFirst(
        '[Event "Club"]',
        '[Event "Club"]\n[Site "https://lichess.org/abcd1234"]',
      ),
    ].join('\n\n');
    store.documents[ref] = Opened(text, scriptedRevision(text));
    final owner = PlayerAnalysis(
      documents: store,
      archive: ScriptedGameStore(),
      cache: GamesCache(store, folder: '/games'),
      sites: const [],
      pending: PendingWrites(),
      archiveCopies: '/archive',
    );
    addTearDown(owner.dispose);
    await owner.select(
      Player.create('Alex').edited({
        'pgn_files': [ref.path],
      }),
    );
    List<String> shown(Set<TimeClass> speeds) {
      owner.speeds = speeds;
      return [
        for (final i in owner.gameIndexes)
          owner.corpus!.games[i].tag('TimeControl'),
      ];
    }

    expect(shown({TimeClass.correspondence}), ['1/86400']);
    expect(shown({TimeClass.unknown}), ['']);
    expect(shown({TimeClass.rapid}), ['480']);
    expect(shown({}), hasLength(4));
  });
}

/// A game of Alex's played at [control] on day [day] of the month; no
/// `TimeControl` when null.
String timed(String? control, int day) => game
    .replaceFirst('2026.09.20', '2026.09.$day')
    .replaceFirst(
      '[Result "1-0"]',
      '${control == null ? '' : '[TimeControl "$control"]\n'}[Result "1-0"]',
    );

class _DelayedGames implements RecentGames {
  final answer = Completer<GamesFetch>();
  @override
  GameSite get site => GameSite.lichess;
  @override
  Future<GamesFetch> recent(String username, {required int max}) =>
      answer.future;
}
