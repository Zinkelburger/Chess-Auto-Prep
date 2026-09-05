@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/services/lichess_api_client.dart';
import 'package:chess_auto_prep/services/live_explorer_service.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:chess_auto_prep/services/master_games/master_games_service.dart';
import 'package:chess_auto_prep/widgets/opening_explorer/opening_explorer_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers every Lichess lookup with one move and one listed game.
class _ScriptedClient extends LichessApiClient {
  _ScriptedClient() : super.fresh();

  @override
  Future<ExplorerResponse?> fetchExplorer(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '2000,2200,2500',
    bool useMasters = false,
  }) async {
    return ExplorerResponse.fromJson(
      {
        'white': 60,
        'draws': 40,
        'black': 20,
        'moves': [
          {'san': 'Nf3', 'uci': 'g1f3', 'white': 60, 'draws': 40, 'black': 20},
        ],
        'topGames': [
          {
            'id': 'abc',
            'winner': 'white',
            'white': {'name': 'Carlsen', 'rating': 2830},
            'black': {'name': 'Nakamura', 'rating': 2790},
            'year': 2024,
            'uci': 'g1f3',
          },
        ],
      },
      fen: fen,
      gameSource: ExplorerGameSource.lichess,
    );
  }
}

const _pgn = '''
[Event "Tata Steel"]
[Site "Wijk aan Zee"]
[Date "2026.01.21"]
[White "Local,Player"]
[Black "Other,One"]
[Result "1-0"]
[WhiteElo "2600"]
[BlackElo "2500"]

1. e4 c5 2. Nc3 1-0

[Event "Titled Tue"]
[Site "chess.com INT"]
[Date "2026.02.03"]
[White "Blitzer,A"]
[Black "Blitzer,B"]
[Result "0-1"]

1. e4 c5 2. f4 0-1
''';

const _fen = 'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';

void main() {
  late Directory tmp;
  late MasterGamesService masterGames;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LiveExplorerService.clearCacheForTest();
    tmp = await Directory.systemTemp.createTemp('explorer_sources');
    final path = '${tmp.path}/master_games.db';
    importPgnIntoMasterGames(
      MasterGamesImportRequest(dbPath: path, pgnText: _pgn, twicIssue: 1660),
    );
    masterGames = MasterGamesService(dbPathProvider: () async => path);
    await masterGames.load();
  });

  tearDown(() async {
    masterGames.dispose();
    await tmp.delete(recursive: true);
  });

  Future<LiveExplorerService> pump(
    WidgetTester tester, {
    Future<void> Function(ExplorerGame)? onOpenGame,
  }) async {
    final svc = LiveExplorerService(
      client: _ScriptedClient(),
      isLoggedIn: () => true,
      localDb: () => masterGames.db,
      debounce: const Duration(milliseconds: 5),
    );
    addTearDown(svc.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 520,
            child: OpeningExplorerPanel(
              service: svc,
              fen: _fen,
              onPlayMove: (_) {},
              onOpenGame: onOpenGame,
              masterGames: masterGames,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return svc;
  }

  testWidgets('lists the games a source names, and opens one on click', (
    tester,
  ) async {
    final gate = Completer<void>();
    ExplorerGame? opened;
    await pump(
      tester,
      onOpenGame: (g) {
        opened = g;
        return gate.future;
      },
    );
    expect(find.text('Top games'), findsOneWidget);
    expect(find.text('Carlsen – Nakamura'), findsOneWidget);

    await tester.tap(find.text('Carlsen – Nakamura'));
    await tester.pump();
    expect(opened?.id, 'abc');
    // While the PGN is on its way the row says so.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('with nowhere to open a game, none are listed', (tester) async {
    await pump(tester);
    expect(find.text('Top games'), findsNothing);
    expect(find.text('Carlsen – Nakamura'), findsNothing);
  });

  testWidgets('TWIC is a source when the local database has games', (
    tester,
  ) async {
    await pump(tester, onOpenGame: (_) async {});
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('TWIC'), findsOneWidget);

    await tester.tap(find.text('TWIC'));
    await tester.pumpAndSettle();
    expect(find.text('TWIC · All games'), findsOneWidget);
    expect(find.text('Nc3'), findsOneWidget);
    expect(find.text('f4'), findsOneWidget);
    expect(find.text('Local P. – Other O.'), findsOneWidget);
    expect(find.text('Blitzer A. – Blitzer B.'), findsOneWidget);

    await tester.tap(find.text('Classical OTB only'));
    await tester.pumpAndSettle();
    expect(find.text('TWIC · Classical OTB only'), findsOneWidget);
    expect(find.text('Nc3'), findsOneWidget);
    expect(find.text('f4'), findsNothing);
    expect(find.text('Blitzer A. – Blitzer B.'), findsNothing);
    // A freshly imported database needs no index.
    expect(find.textContaining('one-time index'), findsNothing);
  });

  testWidgets('classical only on an unindexed database says what to do', (
    tester,
  ) async {
    masterGames.db!.classicalCountsComplete = false;
    SharedPreferences.setMockInitialValues({
      'live_explorer.db': 'twic',
      'live_explorer.twic_classical': true,
    });
    await pump(tester, onOpenGame: (_) async {});
    expect(find.textContaining('one-time index'), findsOneWidget);
  });

  testWidgets('a remembered TWIC choice falls back without the database', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'live_explorer.db': 'twic'});
    final empty = MasterGamesService(
      dbPathProvider: () async => '${tmp.path}/nowhere.db',
    );
    addTearDown(empty.dispose);
    final svc = LiveExplorerService(
      client: _ScriptedClient(),
      isLoggedIn: () => true,
      localDb: () => null,
      debounce: const Duration(milliseconds: 5),
    );
    addTearDown(svc.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 520,
            child: OpeningExplorerPanel(
              service: svc,
              fen: _fen,
              onPlayMove: (_) {},
              masterGames: empty,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Lichess ·'), findsOneWidget);
  });
}
