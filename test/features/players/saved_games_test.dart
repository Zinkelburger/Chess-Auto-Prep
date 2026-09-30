import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/features/players/player_dialogs.dart';
import 'package:chess_auto_prep/features/players/players.dart';
import 'package:chess_auto_prep/features/players/saved_games.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/storage/my_games_files.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:chess_auto_prep/storage/player_reports.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/my_games_fixture.dart';
import '../../support/scripted_store.dart';

String _games(int count) => [
  for (var i = 0; i < count; i++)
    '[Event "Club"]\n[White "A"]\n[Black "B"]\n[Result "*"]\n\n1. e4 *',
].join('\n\n');

void main() {
  late ScriptedDocumentStore store;
  late GamesCache cache;
  late Players players;
  late MemoryAccounts mine;
  late PlayerReports reports;
  late SavedGames saved;

  DocumentRef download(GameSite site, String name) => cache.refFor(site, name);

  void keep(GameSite site, String name, int games) {
    final text = '${_games(games)}\n';
    store.documents[download(site, name)] = Opened(
      text,
      scriptedRevision(text),
    );
  }

  Future<Player> person(String name, Map<String, Object?> fields) async {
    await players.save(Player.create(name).edited(fields));
    await pumpEventQueue();
    return players.players.firstWhere((p) => p.name == name);
  }

  setUp(() {
    store = ScriptedDocumentStore();
    cache = GamesCache(store, folder: '/games_library');
    players = Players(MemoryPlayers(), PendingWrites());
    mine = MemoryAccounts({GameSite.lichess: const Account('Me')});
    reports = PlayerReports();
    saved = SavedGames(players, cache, store, reports, mine);
    keep(GameSite.lichess, 'me', 5);
    keep(GameSite.lichess, 'alex', 3);
    keep(GameSite.chesscom, 'shared', 2);
  });
  tearDown(() {
    saved.dispose();
    players.dispose();
  });

  test('counts downloads and linked files, and names the downloads a delete '
      'would keep', () async {
    const linked = DocumentRef('/collections/alex.pgn');
    final text = _games(4);
    store.documents[linked] = Opened(text, scriptedRevision(text));
    await person('Carol', {'chesscom': 'shared'});
    final alex = await person('Alex', {
      'lichess': 'alex, ME',
      'chesscom': 'shared',
      'pgn_files': [linked.path],
    });
    await saved.refresh();
    final summary = saved.of(alex)!;
    expect(summary.downloaded, 10);
    expect(summary.linked, 4);
    expect(summary.keptGames, 7);
    expect(summary.kept, [
      (site: GameSite.lichess, username: 'ME', otherPerson: null),
      (site: GameSite.chesscom, username: 'shared', otherPerson: 'Carol'),
    ]);
    expect(
      keptLine(summary.kept),
      'Keeps Lichess ME (your account) and Chess.com shared (also Carol’s).',
    );
  });

  test('deleting a person\'s games leaves the user\'s own account and one '
      'another person holds', () async {
    await person('Carol', {'chesscom': 'shared'});
    final alex = await person('Alex', {
      'lichess': 'alex, me',
      'chesscom': 'shared',
    });
    const key =
        '0000000000000000000000000000000000000000000000000000000000000000';
    await reports.keep(key, {'player': alex.id});

    final confirmed = (await saved.current(alex))!;
    expect(
      await saved.delete(alex, confirmed: confirmed),
      isA<GamesDiscarded>(),
    );
    expect(store.deleted.keys, [download(GameSite.lichess, 'alex')]);
    expect(store.documents, contains(download(GameSite.lichess, 'me')));
    expect(store.documents, contains(download(GameSite.chesscom, 'shared')));
    expect(await reports.read(key), isNull);
  });

  test('with the user\'s accounts unreadable nothing is deleted', () async {
    final alex = await person('Alex', {'lichess': 'alex'});
    final confirmed = (await saved.current(alex))!;
    mine.unavailable = true;
    expect(
      await saved.delete(alex, confirmed: confirmed),
      isA<GamesNotDiscarded>(),
    );
    expect(store.deleted, isEmpty);
    expect(saved.deleting, isEmpty);
  });

  test('with the user\'s accounts unreadable what a delete keeps is '
      'unknown and nothing is deletable', () async {
    mine.unavailable = true;
    final alex = await person('Alex', {'lichess': 'alex'});
    final summary = (await saved.current(alex))!;
    expect(summary.downloaded, 3);
    expect(summary.keptKnown, isFalse);
    expect(summary.deletable, 0);

    mine.unavailable = false;
    final readable = (await saved.current(alex))!;
    expect(readable.keptKnown, isTrue);
    expect(readable.deletable, 3);
  });

  test('a change to the user\'s own accounts is counted before a delete is '
      'confirmed, and a delete confirmed before it touches nothing', () async {
    final alex = await person('Alex', {'lichess': 'alex'});
    final before = (await saved.current(alex))!;
    expect(before.deletable, 3);

    await mine.setUsername(GameSite.lichess, 'alex');
    final after = (await saved.current(alex))!;
    expect(after.kept, [
      (site: GameSite.lichess, username: 'alex', otherPerson: null),
    ]);
    expect(after.deletable, 0);

    expect(
      await saved.delete(alex, confirmed: before),
      isA<GamesNotDiscarded>(),
    );
    expect(store.deleted, isEmpty);
  });

  test('a change to a person that touches no games file reads nothing; a '
      'new account is counted', () async {
    final alex = await person('Alex', {'lichess': 'alex'});
    await pumpEventQueue();
    expect(saved.of(alex)!.downloaded, 3);
    final reads = store.opens;
    await players.save(alex.edited({'notes': 'plays the Najdorf'}));
    await pumpEventQueue();
    expect(store.opens, reads);
    final current = players.players.single;
    await players.save(current.edited({'chesscom': 'shared'}));
    await pumpEventQueue();
    expect(saved.of(players.players.single)!.downloaded, 5);
  });
}
