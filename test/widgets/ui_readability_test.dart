import 'package:chess_auto_prep/features/games/services/games_window.dart';
import 'package:chess_auto_prep/features/games/widgets/games_window_picker.dart';
import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import 'package:chess_auto_prep/features/tactics/widgets/tactics_browse_panel.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void expectReadable(WidgetTester tester, Finder label) {
  final rich = tester.widget<RichText>(
    find.descendant(of: label, matching: find.byType(RichText)),
  );
  var foreground = rich.text.style!.color!;
  for (final opacity in tester.widgetList<Opacity>(
    find.ancestor(of: label, matching: find.byType(Opacity)),
  )) {
    foreground = foreground.withValues(alpha: foreground.a * opacity.opacity);
  }
  const background = AppColors.surface;
  final actual = Color.alphaBlend(foreground, background);
  expect(
    (actual.computeLuminance() + .05) / (background.computeLuminance() + .05),
    greaterThanOrEqualTo(4.5),
  );
}

void main() {
  for (final width in [360.0, 520.0, 1000.0]) {
    testWidgets('tactics keep readable one-star rows and actions at $width', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var trained = false;
      const position = TacticsPosition(
        fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        userMove: 'h4',
        correctLine: ['e4', 'e5', 'Nf3'],
        mistakeType: '??',
        mistakeAnalysis: '',
        gameWhite: 'A player with a very long imported display name',
        gameBlack: 'Another long imported player name',
        gameResult: '1-0',
        gameDate: '2026.09.01',
        gameId: 'test',
        rating: 1,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: TacticsBrowsePanel(
                positions: const [position],
                onSelectTactic: (_, _) => trained = true,
                onDeleteTactic: (_) {},
                onEditTactic: (_) {},
                onDeleteAll: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('new'), findsOneWidget);
      expectReadable(
        tester,
        find.text('${position.gameWhite} vs ${position.gameBlack}'),
      );
      if (width < 760) {
        await tester.tap(find.text('Filters and sort'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Filters and sort'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Multi-select'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Tactic actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Train this tactic'));
      } else {
        await tester.tap(find.byTooltip('Train this tactic'));
      }
      await tester.pumpAndSettle();
      expect(trained, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('both game-window alternatives are readable and selectable', (
    tester,
  ) async {
    var window = const GamesWindow();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 400,
              child: GamesWindowPicker(
                window: window,
                onChanged: (value) => setState(() => window = value),
              ),
            ),
          ),
        ),
      ),
    );
    expectReadable(tester, find.text('games'));
    expectReadable(tester, find.text('days'));
    await tester.tap(find.text('days'));
    await tester.pumpAndSettle();
    expect(window.mode, GamesWindowMode.lastDays);
    expectReadable(tester, find.text('games'));
    expectReadable(tester, find.text('days'));
    expect(tester.takeException(), isNull);
  });
}
