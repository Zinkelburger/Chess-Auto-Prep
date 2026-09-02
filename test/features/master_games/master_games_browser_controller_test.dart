@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/my_repertoire_settings.dart';
import 'package:chess_auto_prep/features/master_games/controllers/master_games_browser_controller.dart';
import 'package:chess_auto_prep/features/master_games/services/twic_repertoire_scan.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:chess_auto_prep/services/master_games/master_games_query.dart';
import 'package:chess_auto_prep/services/master_games/master_games_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Two Najdorfs that follow a prepared White line, and one Grünfeld that does
/// not.
const _pgn = '''
[Event "Tata Steel"]
[Site "Wijk aan Zee"]
[Date "2026.01.21"]
[White "Carlsen,Magnus"]
[Black "Nakamura,Hikaru"]
[Result "1-0"]
[WhiteElo "2830"]
[BlackElo "2790"]
[ECO "B90"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 Ng4 1-0

[Event "Prague Open"]
[Site "Prague"]
[Date "2026.01.20"]
[White "Novak,Jan"]
[Black "Svoboda,Petr"]
[Result "0-1"]
[WhiteElo "2410"]
[BlackElo "2505"]
[ECO "B92"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 7. Nb3 Be6 0-1

[Event "Prague Open"]
[Site "Prague"]
[Date "2026.01.19"]
[White "Svoboda,Petr"]
[Black "Novak,Jan"]
[Result "1/2-1/2"]
[WhiteElo "2505"]
[BlackElo "2410"]
[ECO "D85"]

1. d4 Nf6 2. c4 g6 3. Nc3 d5 4. cxd5 Nxd5 1/2-1/2
''';

const _whiteBook = '''
// Color: White

[Event "Najdorf 6.Be3"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 7. Nb3 *
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory books;
  late MasterGamesService service;
  late MyRepertoireSettings repertoire;
  late MasterGamesBrowserController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('mg_browser');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    books = await Directory('${tmp.path}/books').create();
    await File('${books.path}/White.pgn').writeAsString(_whiteBook);

    final dbPath = '${tmp.path}/master_games.db';
    importPgnIntoMasterGames(
      MasterGamesImportRequest(dbPath: dbPath, pgnText: _pgn, twicIssue: 1660),
    );

    service = MasterGamesService(dbPathProvider: () async => dbPath);
    await service.load();

    repertoire = MyRepertoireSettings.forTest();
    controller = MasterGamesBrowserController(
      service: service,
      scanner: TwicRepertoireScanner(
        deviations: GameDeviationService(settings: repertoire),
        settings: repertoire,
      ),
    );
  });

  tearDown(() async {
    controller.dispose();
    service.dispose();
    await tmp.delete(recursive: true);
  });

  test('opens on everything, newest first', () async {
    await controller.search();
    expect(controller.totalCount, 3);
    expect(controller.results, hasLength(3));
    expect(controller.results.first.date, '2026.01.21');
    expect(controller.hasDatabase, isTrue);
  });

  test('filtering narrows the list and the count together', () async {
    await controller.setQuery(const MasterGamesQuery(eco: 'B9'));
    expect(controller.totalCount, 2);
    expect(controller.results, hasLength(2));

    await controller.setQuery(const MasterGamesQuery(player: 'Carlsen'));
    expect(controller.totalCount, 1);
    expect(controller.results.single.black, 'Nakamura,Hikaru');
  });

  test('the repertoire view reports only games that reached a book', () async {
    await repertoire.setPaths(white: true, paths: [books.path]);
    await controller.search();
    await controller.setMode(MasterBrowseMode.myRepertoire);

    final scan = controller.scanResult!;
    expect(scan.matches, hasLength(2), reason: 'the Grünfeld is not mine');
    expect(controller.visibleGames, hasLength(2));

    // Deepest first: the game that reached move 7 of the prepared line.
    final deepest = scan.matches.first;
    expect(deepest.ranPastYourPrep, isTrue);
    expect(deepest.game.white, 'Novak,Jan');

    final tested = scan.matches[1];
    expect(tested.testedYourChoice, isTrue);
    expect(tested.report.playedSan, 'Ng4');

    // And the row-level lookup the list uses agrees.
    expect(controller.matchFor(tested.game)?.report.playedSan, 'Ng4');
    expect(controller.matchFor(controller.results.last), isNull);
  });

  test(
    'changing the filters drops a stale scan and leaves that view',
    () async {
      await repertoire.setPaths(white: true, paths: [books.path]);
      await controller.search();
      await controller.setMode(MasterBrowseMode.myRepertoire);
      expect(controller.scanResult, isNotNull);

      await controller.setQuery(const MasterGamesQuery(eco: 'D'));

      expect(controller.scanResult, isNull);
      expect(controller.mode, MasterBrowseMode.all);
      expect(controller.results, hasLength(1));
    },
  );

  test('the scan honours the filters it was given', () async {
    await repertoire.setPaths(white: true, paths: [books.path]);
    // Only the Grünfeld — nothing here touches the White book.
    await controller.setQuery(const MasterGamesQuery(eco: 'D85'));
    await controller.setMode(MasterBrowseMode.myRepertoire);

    expect(controller.scanResult!.scanned, 1);
    expect(controller.scanResult!.matches, isEmpty);
  });

  test('writing a collection produces a PGN of the visible games', () async {
    await controller.setQuery(const MasterGamesQuery(eco: 'B9'));
    final path = await controller.writeCollection(label: 'B9 games');

    final text = await File(path).readAsString();
    expect(path, endsWith('b9-games.pgn'));
    expect('[Event '.allMatches(text), hasLength(2));
    expect(text, contains('[Source "TWIC 1660"]'));
    expect(text, contains('6. Be3'));
  });

  test('the viewer index points at the game that was clicked', () async {
    await controller.search();
    final second = controller.results[1];
    expect(controller.indexOf(second), 1);
  });

  test('paging stops when everything is loaded', () async {
    await controller.setQuery(const MasterGamesQuery());
    expect(controller.canLoadMore, isFalse);
    await controller.loadMore();
    expect(controller.results, hasLength(3));
  });
}
