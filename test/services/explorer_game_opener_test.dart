@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/services/explorer_game_opener.dart';
import 'package:chess_auto_prep/services/lichess_api_client.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers the PGN endpoints from a map, no network.
class _ScriptedClient extends LichessApiClient {
  _ScriptedClient() : super.fresh();

  final Map<String, String> pgns = {};
  final List<(String, bool)> asked = [];

  @override
  Future<String?> fetchGamePgn(String id, {required bool masters}) async {
    asked.add((id, masters));
    return pgns[id];
  }
}

const _pgn = '''
[Event "Tata Steel"]
[Site "Wijk aan Zee"]
[Date "2026.01.21"]
[White "Carlsen,Magnus"]
[Black "Nakamura,Hikaru"]
[Result "1-0"]

1. e4 c5 2. Nf3 d6 1-0

[Event "Prague Open"]
[Site "Prague"]
[Date "2026.01.20"]
[White "Novak,Jan"]
[Black "Svoboda,Petr"]
[Result "1/2-1/2"]

1. d4 Nf6 2. c4 e6 1/2-1/2
''';

const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
const _afterNf3 =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';

ExplorerGame _twic(int id) => ExplorerGame(
  id: '$id',
  source: ExplorerGameSource.twic,
  white: id == 1 ? 'Carlsen,Magnus' : 'Novak,Jan',
  black: id == 1 ? 'Nakamura,Hikaru' : 'Svoboda,Petr',
  whiteElo: null,
  blackElo: null,
  result: '*',
  year: null,
);

void main() {
  late Directory tmp;
  late MasterGamesDb db;
  late _ScriptedClient client;
  late ExplorerGameOpener opener;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('explorer_opener');
    final path = '${tmp.path}/master_games.db';
    importPgnIntoMasterGames(
      MasterGamesImportRequest(dbPath: path, pgnText: _pgn, twicIssue: 1660),
    );
    db = MasterGamesDb.open(path, readOnly: true);
    client = _ScriptedClient();
    opener = ExplorerGameOpener(
      client: client,
      localDb: () => db,
      collectionsDirectory: () async => tmp,
    );
  });

  tearDown(() async {
    db.close();
    await tmp.delete(recursive: true);
  });

  File collection() => File('${tmp.path}/${ExplorerGameOpener.collectionName}');

  test('a local game is written to the collection at the position', () async {
    final opened = (await opener.open(_twic(1), fen: _afterNf3))!;
    expect(opened.path, collection().path);
    expect(opened.index, 0);
    expect(opened.ply, 3);
    expect(opened.label, 'Carlsen – Nakamura');
    final text = await collection().readAsString();
    expect(text, contains('[White "Carlsen,Magnus"]'));
    expect(client.asked, isEmpty);
  });

  test(
    'games accumulate, and one opened twice is found not appended',
    () async {
      await opener.open(_twic(1), fen: _afterE4);
      final second = (await opener.open(_twic(2), fen: _afterE4))!;
      expect(second.index, 1);
      expect(second.ply, isNull, reason: 'a d4 game never reaches 1.e4');

      final again = (await opener.open(_twic(1), fen: _afterE4))!;
      expect(again.index, 0);
      expect(again.ply, 1);
      final text = await collection().readAsString();
      expect(RegExp(r'\[Event ').allMatches(text).length, 2);
    },
  );

  test(
    'a Lichess game is fetched from the endpoint its source names',
    () async {
      client.pgns['abc'] = '[White "A"]\n[Black "B"]\n\n1. e4 e5 *';
      const game = ExplorerGame(
        id: 'abc',
        source: ExplorerGameSource.masters,
        white: 'A',
        black: 'B',
        whiteElo: null,
        blackElo: null,
        result: '*',
        year: null,
      );
      final opened = (await opener.open(game, fen: _afterE4))!;
      expect(client.asked, [('abc', true)]);
      expect(opened.index, 0);
      expect(opened.ply, 1);

      const player = ExplorerGame(
        id: 'xyz',
        source: ExplorerGameSource.lichess,
        white: 'C',
        black: 'D',
        whiteElo: null,
        blackElo: null,
        result: '*',
        year: null,
      );
      expect(await opener.open(player, fen: _afterE4), isNull);
      expect(client.asked.last, ('xyz', false));
    },
  );

  test('an unknown local id cannot be opened', () async {
    expect(await opener.open(_twic(99), fen: _afterE4), isNull);
    expect(await collection().exists(), isFalse);
  });
}
