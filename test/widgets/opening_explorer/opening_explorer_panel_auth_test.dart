import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/services/lichess_api_client.dart';
import 'package:chess_auto_prep/services/live_explorer_service.dart';
import 'package:chess_auto_prep/widgets/opening_explorer/opening_explorer_panel.dart';

/// Never reached in these tests — a logged-out panel must not fetch at all.
class _NeverCalledClient extends LichessApiClient {
  _NeverCalledClient() : super.fresh();

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

  testWidgets('logged out, the panel asks for a Lichess login', (tester) async {
    final client = _NeverCalledClient();
    final service = LiveExplorerService(
      client: client,
      isLoggedIn: () => false,
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

    expect(find.text('Lichess login needed'), findsOneWidget);
    expect(find.text('Open Lichess to log in'), findsOneWidget);
    expect(find.text('Could not reach the Lichess explorer.'), findsNothing);
    expect(client.calls, 0, reason: 'no point asking an API that will 401');
  });
}
