import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/services/lichess_api_client.dart';
import 'package:chess_auto_prep/services/live_explorer_service.dart';
import 'package:chess_auto_prep/widgets/opening_explorer/explorer_move_row.dart';
import 'package:chess_auto_prep/widgets/opening_explorer/opening_explorer_panel.dart';

/// Answers every lookup with the same two-move position, no network.
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
    return ExplorerResponse.fromJson({
      'white': 90,
      'draws': 60,
      'black': 50,
      'opening': {'eco': 'B20', 'name': 'Sicilian Defense'},
      'moves': [
        {'san': 'Nf3', 'uci': 'g1f3', 'white': 60, 'draws': 40, 'black': 20},
        {'san': 'Nc3', 'uci': 'b1c3', 'white': 30, 'draws': 20, 'black': 30},
      ],
    }, fen: fen);
  }
}

/// [_ScriptedClient] with a valve: while [gate] is open, lookups hang, so a
/// test can inspect the panel mid-load.
class _GatedClient extends _ScriptedClient {
  Completer<void>? gate;

  @override
  Future<ExplorerResponse?> fetchExplorer(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '2000,2200,2500',
    bool useMasters = false,
  }) async {
    await gate?.future;
    return super.fetchExplorer(
      fen,
      variant: variant,
      speeds: speeds,
      ratings: ratings,
      useMasters: useMasters,
    );
  }
}

const _fenA = 'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
const _fenB = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LiveExplorerService.clearCacheForTest();
  });

  Future<LiveExplorerService> pumpPanel(
    WidgetTester tester, {
    required String fen,
    required ValueChanged<ExplorerMove?> onHoverMove,
    ValueChanged<String>? onPlayMove,
    LiveExplorerService? service,
    bool settle = true,
  }) async {
    final svc =
        service ??
        LiveExplorerService(
          client: _ScriptedClient(),
          isLoggedIn: () => true,
          debounce: const Duration(milliseconds: 5),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 400,
            child: OpeningExplorerPanel(
              service: svc,
              fen: fen,
              onPlayMove: onPlayMove ?? (_) {},
              onHoverMove: onHoverMove,
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return svc;
  }

  testWidgets('renders the opening, column captions, rows and Σ totals', (
    tester,
  ) async {
    final svc = await pumpPanel(tester, fen: _fenA, onHoverMove: (_) {});
    addTearDown(svc.dispose);

    expect(find.text('B20'), findsOneWidget);
    expect(find.text('Sicilian Defense'), findsOneWidget);
    expect(find.text('Move'), findsOneWidget);
    expect(find.text('White / Draw / Black'), findsOneWidget);
    expect(find.text('Nf3'), findsOneWidget);
    expect(find.text('Nc3'), findsOneWidget);
    expect(find.text('Σ'), findsOneWidget);
    expect(find.byType(ExplorerTotalsRow), findsOneWidget);
    // Σ share is the whole position; Nf3 is 120 of 200 games.
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('60%'), findsWidgets);
    // The filter line names the query rather than counting ticked boxes.
    expect(
      find.text('Lichess · Blitz, Rapid, Classical · 2000+'),
      findsOneWidget,
    );
  });

  testWidgets('a row click plays the move by SAN', (tester) async {
    final played = <String>[];
    final svc = await pumpPanel(
      tester,
      fen: _fenA,
      onHoverMove: (_) {},
      onPlayMove: played.add,
    );
    addTearDown(svc.dispose);

    await tester.tap(find.text('Nc3'));
    expect(played, ['Nc3']);
  });

  testWidgets('hovering reports the move and a new position clears it', (
    tester,
  ) async {
    final hovered = <ExplorerMove?>[];
    final svc = await pumpPanel(tester, fen: _fenA, onHoverMove: hovered.add);
    addTearDown(svc.dispose);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();

    await mouse.moveTo(tester.getCenter(find.text('Nf3')));
    await tester.pumpAndSettle();
    expect(hovered.map((m) => m?.uci), ['g1f3']);

    // Board moved on while the pointer sat on the row: the old arrow must be
    // cleared before the new rows arrive. (The pointer still sits over the
    // rebuilt row, so the new position's move may be reported after that —
    // that arrow is for the right position.)
    await pumpPanel(tester, fen: _fenB, onHoverMove: hovered.add, service: svc);
    expect(hovered.length, greaterThanOrEqualTo(2));
    expect(hovered[1], isNull);
  });

  testWidgets('holds the old rows, inert, while the next position loads', (
    tester,
  ) async {
    final client = _GatedClient();
    final played = <String>[];
    final svc = LiveExplorerService(
      client: client,
      isLoggedIn: () => true,
      debounce: const Duration(milliseconds: 5),
    );
    addTearDown(svc.dispose);

    await pumpPanel(
      tester,
      fen: _fenA,
      onHoverMove: (_) {},
      onPlayMove: played.add,
      service: svc,
    );
    expect(find.text('Nf3'), findsOneWidget);

    // Next position, with the answer held back.
    client.gate = Completer<void>();
    await pumpPanel(
      tester,
      fen: _fenB,
      onHoverMove: (_) {},
      onPlayMove: played.add,
      service: svc,
      settle: false,
    );

    expect(
      find.text('Nf3'),
      findsOneWidget,
      reason: 'the table stays put instead of collapsing to a spinner',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // Those rows belong to the position we just left — they must not play.
    await tester.tap(find.text('Nc3'), warnIfMissed: false);
    await tester.pump();
    expect(played, isEmpty);

    client.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Nf3'), findsOneWidget);
  });
}
