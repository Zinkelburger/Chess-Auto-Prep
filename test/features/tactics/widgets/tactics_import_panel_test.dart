/// The Tactics card: what is playable, and the button that plays it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import 'package:chess_auto_prep/features/tactics/models/tactics_session_settings.dart';
import 'package:chess_auto_prep/features/tactics/controllers/tactics_session_controller.dart';
import 'package:chess_auto_prep/features/tactics/widgets/tactics_import_panel.dart';

/// A puzzle mined today, so no expiry window can filter it out.
TacticsPosition _position({required String id, String mistakeType = '??'}) {
  final now = DateTime.now();
  final date =
      '${now.year}.${now.month.toString().padLeft(2, '0')}.'
      '${now.day.toString().padLeft(2, '0')}';
  return TacticsPosition(
    fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    userMove: 'a3',
    correctLine: const ['e4'],
    mistakeType: mistakeType,
    mistakeAnalysis: 'test',
    gameWhite: 'A',
    gameBlack: 'B',
    gameResult: '1-0',
    gameDate: date,
    gameId: id,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<TacticsSessionController> pumpPanel(
    WidgetTester tester, {
    required List<TacticsPosition> positions,
    bool isImporting = false,
  }) async {
    final session = TacticsSessionController();
    addTearDown(session.dispose);
    // Never expire, so the fixtures stay playable.
    session.setSessionSettings(
      const TacticsSessionSettings().copyWith(clearMaxAgeDays: true),
      save: false,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>(create: (_) => AppState()),
          ChangeNotifierProvider<TacticsSessionController>.value(
            value: session,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TacticsImportPanel(
                isImporting: isImporting,
                positions: positions,
                onClearDatabase: () {},
                onBrowseTactics: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return session;
  }

  testWidgets('the count and the button that plays it are on one card', (
    tester,
  ) async {
    final started = <int>[];
    final session = await pumpPanel(
      tester,
      positions: [
        _position(id: '1'),
        _position(id: '2'),
        _position(id: '3', mistakeType: '?'),
      ],
    );
    session.attachPanel(TacticsPanelHooks(start: () => started.add(1)));
    await tester.pump();

    expect(
      find.textContaining('Ready to play: 2 blunders, 1 mistake'),
      findsOneWidget,
    );
    // The verb for that sentence is right underneath it, carrying the same
    // number — not on the far side of the screen.
    expect(find.text('Play tactics (3)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('play-tactics-button')));
    expect(started, hasLength(1));
  });

  testWidgets('it stays pressable while the analysis is still running', (
    tester,
  ) async {
    await pumpPanel(tester, positions: [_position(id: '1')], isImporting: true);

    expect(
      find.textContaining('more are added as the review finds them'),
      findsOneWidget,
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('play-tactics-button')),
    );
    expect(
      button.onPressed,
      isNotNull,
      reason: 'you play what has been mined so far while the rest arrives',
    );
  });

  testWidgets('with nothing mined it is dead, and says the analysis is on', (
    tester,
  ) async {
    await pumpPanel(tester, positions: const [], isImporting: true);

    expect(
      find.textContaining('Analysing your games'),
      findsOneWidget,
      reason: 'auto-start means the usual empty database is a busy one',
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('play-tactics-button')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Play tactics'), findsOneWidget);
  });
}
