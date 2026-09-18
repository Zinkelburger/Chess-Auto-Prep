import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import '../support/runtime_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/position_analysis.dart';
import 'package:chess_auto_prep/widgets/position_analysis_widget.dart';
import '../support/board_engine_fixture.dart';

RuntimeSettings? _settings;
RuntimeSettings get settings => _settings ??= testRuntimeSettings();
void main() {
  setUp(() {
    _settings = null;
    addTearDown(() => _settings?.dispose());
  });
  setUp(useScriptedBoardEngine);

  testWidgets(
    'games open inline and return to the list; scratch has a clear name',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
      final analysis = PositionAnalysis();
      final game = GameInfo(
        white: 'Jane',
        black: 'Alex',
        pgnText: '[White "Jane"]\n[Black "Alex"]\n[Result "*"]\n\n1. e4 e5 *',
      );
      analysis.linkFenToGame(fen, analysis.addGame(game));
      Widget host(int generation) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PositionAnalysisWidget(
            playerIsWhite: true,
            analysis: analysis,
            externalNavigateFen: fen,
            externalNavigateGeneration: generation,
          ),
        ),
      );
      await pumpRuntimeWidget(tester, settings, host(0));
      await pumpRuntimeWidget(tester, settings, host(1));
      await tester.pumpAndSettle();
      expect(find.text('PGN'), findsNothing);
      expect(find.text('Try moves'), findsOneWidget);
      await tester.tap(find.text('Games'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jane vs Alex'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('back-to-games')), findsOneWidget);
      await tester.tap(find.byKey(const Key('back-to-games')));
      await tester.pumpAndSettle();
      expect(find.text('Jane vs Alex'), findsOneWidget);
      expect(find.byKey(const Key('back-to-games')), findsNothing);
      await tester.tap(find.text('Try moves'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stacks analysis panes cleanly on narrow layouts', (
    tester,
  ) async {
    await pumpRuntimeWidget(
      tester,
      settings,
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 800,
              child: PositionAnalysisWidget(playerIsWhite: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Positions'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(find.byType(PositionAnalysisWidget), findsOneWidget);
  });

  testWidgets('↑/↓ step through the weak-positions list', (tester) async {
    final analysis = PositionAnalysis();
    for (final entry in {'fen-mid': 5, 'fen-low': 1, 'fen-high': 9}.entries) {
      analysis.addPositionStats(
        PositionStats(
          fen: entry.key,
          games: 10,
          wins: entry.value,
          losses: 10 - entry.value,
        ),
      );
    }

    await pumpRuntimeWidget(
      tester,
      settings,
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 800,
              child: PositionAnalysisWidget(
                playerIsWhite: true,
                analysis: analysis,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The screen's Focus owns key events and forwards previous/next to the
    // list. Every chord AppShortcut.nextItem/previousItem advertises has to
    // work through the shared registry rather than a screen-specific key.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('1 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pumpAndSettle();
    expect(
      find.text('1 of 3'),
      findsOneWidget,
      reason: 'letter keys are no longer navigation aliases',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.text('1 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.text('1 of 3'), findsOneWidget, reason: 'stops at the top');
  });
}
