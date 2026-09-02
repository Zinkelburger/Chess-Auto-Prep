@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/services/master_games/game_authority.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:chess_auto_prep/services/master_games/master_games_query.dart';
import 'package:flutter_test/flutter_test.dart';

/// Three over-the-board games and one Titled Tuesday, which is the split that
/// makes the authority filter worth having.
const _pgn = '''
[Event "Tata Steel"]
[Site "Wijk aan Zee"]
[Date "2026.01.20"]
[Round "3"]
[White "Carlsen,Magnus"]
[Black "Nakamura,Hikaru"]
[Result "1-0"]
[WhiteElo "2830"]
[BlackElo "2790"]
[ECO "B90"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 1-0

[Event "Tata Steel"]
[Site "Wijk aan Zee"]
[Date "2026.01.21"]
[Round "4"]
[White "Nakamura,Hikaru"]
[Black "Carlsen,Magnus"]
[Result "1/2-1/2"]
[WhiteElo "2790"]
[BlackElo "2830"]
[ECO "C50"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 1/2-1/2

[Event "Prague Open"]
[Site "Prague"]
[Date "2025.06.02"]
[Round "1"]
[White "Novak,Jan"]
[Black "Svoboda,Petr"]
[Result "0-1"]
[WhiteElo "2210"]
[BlackElo "2305"]
[ECO "B92"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be2 e5 0-1

[Event "Titled Tue 20th Jan 2026"]
[Site "chess.com INT"]
[Date "2026.01.20"]
[Round "5"]
[White "Carlsen,Magnus"]
[Black "Firouzja,Alireza"]
[Result "1-0"]
[WhiteElo "2830"]
[BlackElo "2760"]
[ECO "B90"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 1-0
''';

void main() {
  group('buildMasterGamesWhere', () {
    test('an empty query restricts nothing', () {
      final built = buildMasterGamesWhere(const MasterGamesQuery());
      expect(built.where, isEmpty);
      expect(built.args, isEmpty);
      expect(const MasterGamesQuery().isUnfiltered, isTrue);
    });

    test('one player matches either colour', () {
      final built = buildMasterGamesWhere(
        const MasterGamesQuery(player: 'Carlsen'),
      );
      expect(built.where, contains('white LIKE ?'));
      expect(built.where, contains('OR black LIKE ?'));
      expect(built.args, ['Carlsen%', 'Carlsen%']);
    });

    test('a pairing matches either seating', () {
      final built = buildMasterGamesWhere(
        const MasterGamesQuery(player: 'Carlsen', opponent: 'Nakamura'),
      );
      expect(built.args, ['Carlsen%', 'Nakamura%', 'Nakamura%', 'Carlsen%']);
    });

    test('an opponent alone behaves like a player', () {
      final built = buildMasterGamesWhere(
        const MasterGamesQuery(opponent: 'So'),
      );
      expect(built.args, ['So%', 'So%']);
    });

    test('blank fields are not clauses', () {
      final built = buildMasterGamesWhere(
        const MasterGamesQuery(player: '   ', eco: '', event: ' '),
      );
      expect(built.where, isEmpty);
    });

    test('ECO is a prefix and event is a substring', () {
      final built = buildMasterGamesWhere(
        const MasterGamesQuery(eco: 'B9', event: 'Tata'),
      );
      expect(built.args, contains('B9%'));
      expect(built.args, contains('%Tata%'));
    });

    test('an Elo floor applies to both players and survives a null rating', () {
      final built = buildMasterGamesWhere(const MasterGamesQuery(minElo: 2600));
      expect(built.where, contains('COALESCE(white_elo, 0) >= ?'));
      expect(built.where, contains('COALESCE(black_elo, 0) >= ?'));
      expect(built.args, [2600, 2600]);
    });

    test('selecting every tier is the same as selecting none', () {
      final all = buildMasterGamesWhere(
        MasterGamesQuery(authorities: GameAuthority.values.toSet()),
      );
      expect(all.where, isEmpty);

      final one = buildMasterGamesWhere(
        const MasterGamesQuery(authorities: {GameAuthority.classical}),
      );
      expect(one.where, 'authority IN (?)');
      expect(one.args, [GameAuthority.classical.code]);
    });

    test('clauses combine with AND', () {
      final built = buildMasterGamesWhere(
        const MasterGamesQuery(player: 'Carlsen', eco: 'B90', minElo: 2700),
      );
      expect(built.where.split(' AND ').length, greaterThanOrEqualTo(3));
    });
  });

  group('masterGamesOrderBy', () {
    test('both orders break ties on id so paging is stable', () {
      expect(masterGamesOrderBy(MasterGamesOrder.newest), endsWith('id DESC'));
      expect(
        masterGamesOrderBy(MasterGamesOrder.strongest),
        endsWith('id DESC'),
      );
    });
  });

  group('against a real database', () {
    late Directory tmp;
    late MasterGamesDb db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('mg_query');
      final path = '${tmp.path}/master_games.db';
      importPgnIntoMasterGames(
        MasterGamesImportRequest(dbPath: path, pgnText: _pgn, twicIssue: 1660),
      );
      db = MasterGamesDb.open(path, readOnly: true);
    });

    tearDown(() async {
      db.close();
      await tmp.delete(recursive: true);
    });

    test('everything comes back newest first', () {
      final games = db.searchGames(const MasterGamesQuery());
      expect(games, hasLength(4));
      expect(games.first.date, '2026.01.21');
      expect(games.last.date, '2025.06.02');
      expect(db.countGames(const MasterGamesQuery()), 4);
    });

    test('a player search finds both colours', () {
      final games = db.searchGames(const MasterGamesQuery(player: 'Carlsen'));
      expect(games, hasLength(3));
      expect(
        games.every(
          (g) => g.white.startsWith('Carlsen') || g.black.startsWith('Carlsen'),
        ),
        isTrue,
      );
    });

    test('a pairing search finds only that pairing', () {
      final games = db.searchGames(
        const MasterGamesQuery(player: 'Carlsen', opponent: 'Nakamura'),
      );
      expect(games, hasLength(2));
    });

    test('an ECO prefix widens, an ECO code narrows', () {
      expect(db.countGames(const MasterGamesQuery(eco: 'B')), 3);
      expect(db.countGames(const MasterGamesQuery(eco: 'B9')), 3);
      expect(db.countGames(const MasterGamesQuery(eco: 'B90')), 2);
    });

    test('an Elo floor excludes the club game', () {
      final games = db.searchGames(const MasterGamesQuery(minElo: 2700));
      expect(games, hasLength(3));
      expect(games.every((g) => (g.whiteElo ?? 0) >= 2700), isTrue);
    });

    test('classical-only drops the Titled Tuesday game', () {
      final games = db.searchGames(
        const MasterGamesQuery(authorities: {GameAuthority.classical}),
      );
      expect(games, hasLength(3));
      expect(games.every((g) => !g.site.endsWith('INT')), isTrue);
    });

    test('strongest order puts the top rating first', () {
      final games = db.searchGames(
        const MasterGamesQuery(order: MasterGamesOrder.strongest),
      );
      expect(
        games.first.whiteElo == 2830 || games.first.blackElo == 2830,
        isTrue,
      );
      expect(games.last.event, 'Prague Open');
    });

    test('paging does not repeat or skip a game', () {
      final first = db.searchGames(const MasterGamesQuery(limit: 2));
      final second = db.searchGames(
        const MasterGamesQuery(limit: 2, offset: 2),
      );
      final ids = {...first.map((g) => g.id), ...second.map((g) => g.id)};
      expect(ids, hasLength(4));
    });

    test('issue bounds match what was imported', () {
      expect(db.countGames(const MasterGamesQuery(fromIssue: 1660)), 4);
      expect(db.countGames(const MasterGamesQuery(fromIssue: 1661)), 0);
      final issues = db.recentIssues();
      expect(issues, hasLength(1));
      expect(issues.first.issue, 1660);
      expect(issues.first.games, 4);
    });

    test('a date window selects the right year', () {
      expect(db.countGames(const MasterGamesQuery(fromDate: '2026.01.01')), 3);
      expect(db.countGames(const MasterGamesQuery(toDate: '2025.12.31')), 1);
    });
  });
}
