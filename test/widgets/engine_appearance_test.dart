import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/design_system/theme/workspace_theme.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/utils/app_messages.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/clickable_move_line.dart';
import 'package:chess_auto_prep/widgets/engine/engine_gate.dart';
import 'package:chess_auto_prep/widgets/engine/engine_pv_row.dart';
import 'package:chess_auto_prep/widgets/engine/floating_board_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return (first > second ? first + .05 : second + .05) /
      (first > second ? second + .05 : first + .05);
}

Color renderedTextColor(WidgetTester tester, Finder finder) {
  final text = tester.widget<Text>(finder);
  return text.style?.color ??
      DefaultTextStyle.of(tester.element(finder)).style.color!;
}

void main() {
  testWidgets(
    'PV expansion and selected move survive live appearance changes',
    (tester) async {
      final theme = ValueNotifier(AppTheme.dark());
      addTearDown(theme.dispose);
      var tapped = -1;
      await tester.pumpWidget(
        ValueListenableBuilder(
          valueListenable: theme,
          builder: (_, value, _) => MaterialApp(
            theme: value,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: [
                  EnginePvRow(
                    evaluation: '+0.20',
                    sanMoves: const ['e4', 'e5'],
                    startPly: 0,
                    onMoveTapped: (index) => tapped = index,
                  ),
                  ClickableMoveLineWidget(
                    sanMoves: const ['Nf3'],
                    startPly: 2,
                    activeMoveIndex: 0,
                    onMoveTapped: (_) {},
                  ),
                  const EngineBusyNotice(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Show full line'));
      await tester.pumpAndSettle();
      for (final value in [AppTheme.dark(), AppTheme.light()]) {
        theme.value = value;
        await tester.pumpAndSettle();
        expect(find.byTooltip('Collapse line'), findsOneWidget);
        final surface = value.extension<WorkspaceTheme>()!.panel;
        expect(
          contrast(renderedTextColor(tester, find.text('+0.20')), surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(renderedTextColor(tester, find.text('e4')), surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(
            renderedTextColor(tester, find.text('Nf3')),
            value.colorScheme.primaryContainer,
          ),
          greaterThanOrEqualTo(4.5),
        );
        final notice = find.descendant(
          of: find.byType(EngineBusyNotice),
          matching: find.byType(Text),
        );
        for (final text in notice.evaluate()) {
          expect(
            contrast(
              renderedTextColor(tester, find.byWidget(text.widget)),
              value.colorScheme.tertiaryContainer,
            ),
            greaterThanOrEqualTo(4.5),
          );
        }
        await tester.tap(find.text('e5'));
        expect(tapped, 1);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an open floating preview follows theme without losing position',
    (tester) async {
      final controller = BoardPreviewController();
      final theme = ValueNotifier(AppTheme.dark());
      addTearDown(controller.dispose);
      addTearDown(theme.dispose);
      final previewKey = GlobalKey();
      await tester.pumpWidget(
        ValueListenableBuilder(
          valueListenable: theme,
          builder: (_, value, _) => MaterialApp(
            theme: value,
            home: Scaffold(
              body: FloatingBoardPreview(
                stackKey: previewKey,
                controller: controller,
                flipped: true,
              ),
            ),
          ),
        ),
      );
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      controller.setPreview(
        fen,
        target: BoardPreviewTarget.floating,
        anchorGlobal: const Offset(250, 150),
      );
      await tester.pump(BoardPreviewController.previewDelay);
      await tester.pump();
      final boardElement = tester.element(find.byType(ChessBoardWidget));
      final updated = AppTheme.light().copyWith(
        colorScheme: AppTheme.light().colorScheme.copyWith(
          shadow: const Color(0xFF123456),
        ),
      );
      theme.value = updated;
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(ChessBoardWidget)), same(boardElement));
      final board = tester.widget<ChessBoardWidget>(
        find.byType(ChessBoardWidget),
      );
      expect(board.position.fen, fen);
      expect(board.flipped, isTrue);
      final material = tester.widget<Material>(
        find
            .ancestor(
              of: find.byType(ChessBoardWidget),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.shadowColor, updated.colorScheme.shadow);
      controller.clearPreview();
      await tester.pump();
      expect(find.byType(ChessBoardWidget), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'persistent notice follows theme with readable action and dismiss control',
    (tester) async {
      final theme = ValueNotifier(AppTheme.dark());
      addTearDown(theme.dispose);
      late BuildContext context;
      var actions = 0;
      await tester.pumpWidget(
        ValueListenableBuilder(
          valueListenable: theme,
          builder: (_, value, _) => MaterialApp(
            theme: value,
            home: Scaffold(
              body: Builder(
                builder: (value) {
                  context = value;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      showAppSnackBar(
        context,
        'Engine failed',
        isError: true,
        actionLabel: 'Inspect',
        onAction: () => actions++,
      );
      await tester.pumpAndSettle();
      for (final value in [AppTheme.dark(), AppTheme.light()]) {
        theme.value = value;
        await tester.pumpAndSettle();
        final fill = tester
            .widget<Material>(
              find
                  .descendant(
                    of: find.byType(SnackBar),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color!;
        expect(fill, value.snackBarTheme.backgroundColor);
        expect(
          contrast(renderedTextColor(tester, find.text('Engine failed')), fill),
          greaterThanOrEqualTo(4.5),
        );
        final action = tester.widget<TextButton>(
          find.descendant(
            of: find.byType(SnackBarAction),
            matching: find.byType(TextButton),
          ),
        );
        expect(
          contrast(action.style!.foregroundColor!.resolve({})!, fill),
          greaterThanOrEqualTo(4.5),
        );
        final close = tester.widget<Icon>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byIcon(Icons.close),
          ),
        );
        expect(
          contrast(
            close.color ??
                IconTheme.of(tester.element(find.byIcon(Icons.close))).color!,
            fill,
          ),
          greaterThanOrEqualTo(3),
        );
      }
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Engine failed'), findsOneWidget);
      await tester.tap(find.text('Inspect'));
      await tester.pumpAndSettle();
      expect(actions, 1);
      showAppSnackBar(context, 'Engine failed', isError: true);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
