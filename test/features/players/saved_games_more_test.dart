// The saved-games counts: a changed file counted again, the count kept
// while nothing it read has changed, a count after a delete, and nothing
// said once taken down.
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
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
    saved = SavedGames(players, cache, store, PlayerReports(), mine);
    keep(GameSite.lichess, 'me', 5);
    keep(GameSite.lichess, 'alex', 3);
  });
  tearDown(() => players.dispose());

  test('a file that changed is counted again', () async {
    final alex = await person('Alex', {'lichess': 'alex'});
    await saved.refresh();
    expect(saved.of(alex)!.downloaded, 3);
    keep(GameSite.lichess, 'alex', 4);
    await saved.refresh();
    expect(saved.of(alex)!.downloaded, 4);
    saved.dispose();
  });

  test('what a delete is confirmed with is the count kept, while the '
      'accounts are as they were', () async {
    final alex = await person('Alex', {'lichess': 'alex'});
    await saved.current(alex);
    final reads = mine.snapshots;
    await saved.current(alex);
    expect(mine.snapshots, reads);
    saved.dispose();
  });

  test('a delete counts again after', () async {
    final alex = await person('Alex', {'lichess': 'alex'});
    final confirmed = (await saved.current(alex))!;
    expect(confirmed.downloaded, 3);
    await saved.delete(alex, confirmed: confirmed);
    await pumpEventQueue();
    expect(saved.of(players.players.single)?.downloaded ?? 0, 0);
    saved.dispose();
  });

  test('taken down while it counts, it says nothing', () async {
    await person('Alex', {'lichess': 'alex'});
    final counting = saved.refresh();
    saved.dispose();
    await expectLater(counting, completes);
  });
}
