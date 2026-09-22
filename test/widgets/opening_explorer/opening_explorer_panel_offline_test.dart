/// What the explorer says when it cannot reach Lichess.
///
/// This panel is the one surface with no offline answer: its database lives
/// on lichess.org and nothing is kept on this computer. So the failure has to
/// name the database, say that it needs a connection, and offer the retry —
/// never an empty table, and never a spinner that never resolves.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/services/lichess_api_client.dart';
import 'package:chess_auto_prep/services/live_explorer_service.dart';
import 'package:chess_auto_prep/widgets/opening_explorer/opening_explorer_panel.dart';

/// A client with no connection: every lookup comes back with nothing, which
/// is what `fetchExplorer` returns once its retries are spent.
class _OfflineClient extends LichessApiClient {
  _OfflineClient() : super.fresh();

  int calls = 0;

  @override
  Future<ExplorerResponse?> fetchExplorer(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '2000,2200,2500',
    bool useMasters = false,
  }) async {
    calls++;
    return null;
  }
}

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LiveExplorerService.clearCacheForTest();
  });

  Future<_OfflineClient> pumpOffline(WidgetTester tester) async {
    final client = _OfflineClient();
    final service = LiveExplorerService(
      client: client,
      isLoggedIn: () => true,
      debounce: const Duration(milliseconds: 5),
    );
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OpeningExplorerPanel(
            service: service,
            fen: _startFen,
            onPlayMove: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return client;
  }

  testWidgets('a failed lookup names the database and what it needs', (
    tester,
  ) async {
    await pumpOffline(tester);

    expect(
      find.textContaining('Could not reach the Lichess database'),
      findsOneWidget,
    );
    expect(find.textContaining('needs a connection'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
  });

  testWidgets('Try again asks once more', (tester) async {
    final client = await pumpOffline(tester);
    final before = client.calls;
    expect(before, greaterThan(0), reason: 'the first lookup was attempted');

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(client.calls, before + 1);
    // Still offline, so the panel says the same thing rather than emptying.
    expect(
      find.textContaining('Could not reach the Lichess database'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
  });
}
