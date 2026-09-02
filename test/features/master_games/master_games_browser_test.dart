@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/my_repertoire_settings.dart';
import 'package:chess_auto_prep/features/master_games/controllers/master_games_browser_controller.dart';
import 'package:chess_auto_prep/features/master_games/services/twic_repertoire_scan.dart';
import 'package:chess_auto_prep/features/master_games/widgets/master_games_browser.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:chess_auto_prep/services/master_games/master_games_service.dart';
import 'package:flutter/material.dart';
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
  late Directory tmp;
  late Directory books;
  late MasterGamesService service;
  late MyRepertoireSettings repertoire;
  late MasterGamesBrowserController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('mg_browser_ui');
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
    service.dispose();
    await tmp.delete(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MasterGamesBrowser(appState: AppState(), controller: controller),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists the corpus with what it takes to identify a game', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('Master games'), findsOneWidget);
    expect(find.textContaining('2 games from TWIC issues'), findsOneWidget);
    expect(find.text('Carlsen M. – Nakamura H.'), findsOneWidget);
    expect(
      find.textContaining('B90 · Tata Steel · 2026-01-21'),
      findsOneWidget,
    );
    expect(find.textContaining('2 games match'), findsOneWidget);
  });

  testWidgets('a filter narrows the list', (tester) async {
    await pump(tester);

    await tester.enterText(find.widgetWithText(TextField, 'ECO').first, 'D85');
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();

    expect(find.text('Svoboda P. – Novak J.'), findsOneWidget);
    expect(find.text('Carlsen M. – Nakamura H.'), findsNothing);
  });

  testWidgets('selecting a game shows it, with its moves', (tester) async {
    await pump(tester);

    expect(find.textContaining('Select a game to see it here'), findsOneWidget);
    await tester.tap(find.text('Carlsen M. – Nakamura H.'));
    await tester.pumpAndSettle();

    expect(find.text('Carlsen,Magnus – Nakamura,Hikaru'), findsOneWidget);
    expect(find.text('TWIC 1660'), findsOneWidget);
    expect(find.textContaining('6. Be3 Ng4'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Open in Games'), findsOneWidget);
  });

  testWidgets('the repertoire view says what each game did to your book', (
    tester,
  ) async {
    await repertoire.setPaths(white: true, paths: [books.path]);
    await pump(tester);

    // The scan reads the chapter files off disk, and real I/O never
    // completes inside the fake-async zone `testWidgets` runs in — so it is
    // driven through `runAsync` first; switching the view then finds the
    // result already there.
    await tester.runAsync(() => controller.runScan());
    await tester.tap(find.text('In my repertoire'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('1 of 2 games reached your books'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Left White (White) at move 6 with Ng4'),
      findsOneWidget,
    );
    // The Grünfeld is not in any of my books, so it is gone from the list.
    expect(find.text('Svoboda P. – Novak J.'), findsNothing);
  });

  testWidgets('with no book designated it explains rather than showing zero', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.text('In my repertoire'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('No repertoire is designated as yours'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Designate one on the home page'),
      findsOneWidget,
    );
  });

  testWidgets('it lays out in a small window without overflowing', (
    tester,
  ) async {
    await pump(tester, size: const Size(900, 600));
    expect(tester.takeException(), isNull);
  });
}
