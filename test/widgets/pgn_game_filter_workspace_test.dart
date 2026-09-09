import 'package:chess_auto_prep/core/board_editor_controller.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/widgets/board_editor/board_editor_widget.dart';
import 'package:chess_auto_prep/widgets/lines_preview_panel.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_game_filter_workspace.dart';
import 'package:chess_auto_prep/widgets/slice/header_filters.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
const _games = <GameRecord>[
  (
    headers: {
      'White': 'Fischer',
      'Black': 'Spassky',
      'Event': 'World Championship',
      'Date': '1972.01.01',
    },
    pgnText: '1. e4 e5 *',
  ),
  (
    headers: {
      'White': 'Spassky',
      'Black': 'Fischer',
      'Event': 'Candidates',
      'Date': '1971.01.01',
    },
    pgnText: '1. d4 Nf6 2. c4 g6 3. Nc3 Bg7 4. e4 d6 *',
  ),
];

Future<void> _open(
  WidgetTester tester, {
  SliceApplyCallback? onApply,
  SliceConfig? initialConfig,
  Size size = const Size(1280, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PgnGameFilterWorkspace(
          allGames: _games,
          initialConfig: initialConfig,
          currentFen: _fen,
          collectionName: 'Practice.pgn',
          presets: const [
            (
              label: 'Fischer as White',
              shortLabel: 'as White',
              filter: HeaderFilterConfig(
                field: 'White',
                mode: MatchMode.contains,
                value: 'Fischer',
              ),
            ),
            (
              label: 'Fischer as Black',
              shortLabel: 'as Black',
              filter: HeaderFilterConfig(
                field: 'Black',
                mode: MatchMode.contains,
                value: 'Fischer',
              ),
            ),
          ],
          onApply: onApply ?? (_, _) {},
        ),
      ),
    ),
  );
  await _finishMatching(tester);
}

Finder get _apply => find.byKey(const ValueKey('apply-game-filters'));

Future<void> _finishMatching(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 350));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'presets create visible editable rows and combine with a KID position',
    (tester) async {
      List<int>? applied;
      SliceConfig? config;
      await _open(
        tester,
        onApply: (indices, value) {
          applied = indices;
          config = value;
        },
      );
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Practice.pgn · 2 games'), findsOneWidget);
      expect(find.byType(LinesPreviewPanel), findsOneWidget);
      expect(
        tester
            .widget<LinesPreviewPanel>(find.byType(LinesPreviewPanel))
            .showSearch,
        isFalse,
      );
      await tester.tap(find.text('Fischer as Black'));
      await _finishMatching(tester);
      final controller = tester
          .widget<HeaderFilters>(find.byType(HeaderFilters))
          .controller;
      expect(controller.headerRows.single.field, 'Black');
      expect(controller.headerRows.single.controller.text, 'Fischer');
      expect(find.text('Show 1 game'), findsOneWidget);
      await tester.ensureVisible(find.text('King’s Indian'));
      await tester.tap(find.text('King’s Indian'));
      await _finishMatching(tester);
      expect(find.text('Show 1 game'), findsOneWidget);
      await tester.tap(_apply);
      await tester.pump();
      expect(applied, [1]);
      expect(config!.headerFilters.single.field, 'Black');
      expect(config!.positionInput, isNotNull);
      expect(find.byType(PgnGameFilterWorkspace), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('never applies stale results or an invalid FEN or regex', (
    tester,
  ) async {
    await _open(
      tester,
      initialConfig: const SliceConfig(
        headerFilters: [
          HeaderFilterConfig(
            field: 'Black',
            mode: MatchMode.contains,
            value: 'Fischer',
          ),
        ],
      ),
    );
    await _finishMatching(tester);
    final controller = tester
        .widget<HeaderFilters>(find.byType(HeaderFilters))
        .controller;
    controller.setHeaderValue(0, 'Spassky');
    await tester.pump();
    expect(tester.widget<FilledButton>(_apply).onPressed, isNull);
    expect(find.byType(LinesPreviewPanel), findsNothing);
    await _finishMatching(tester);
    expect(tester.widget<FilledButton>(_apply).onPressed, isNotNull);
    controller.positionText.text = 'not a position';
    await tester.pump();
    expect(tester.widget<FilledButton>(_apply).onPressed, isNull);
    controller.clearPosition();
    controller.setHeaderMode(0, MatchMode.regex);
    controller.setHeaderValue(0, '[');
    await tester.pump();
    expect(tester.widget<FilledButton>(_apply).onPressed, isNull);
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('Show 2 games'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('board changes must be used or discarded before applying', (
    tester,
  ) async {
    await _open(tester);
    await tester.ensureVisible(find.text('Set up a board'));
    await tester.tap(find.text('Set up a board'));
    await tester.pumpAndSettle();
    final board = tester
        .widget<BoardEditorWidget>(find.byType(BoardEditorWidget))
        .controller;
    expect(board.tool, isA<PointerTool>());
    board.movePiece(Square.e2, Square.e4);
    board.setTurn(Side.black);
    await tester.pump();
    expect(tester.widget<FilledButton>(_apply).onPressed, isNull);
    expect(find.text('Board setup has unapplied changes'), findsOneWidget);
    await tester.ensureVisible(find.text('Use this position'));
    await tester.tap(find.text('Use this position'));
    await _finishMatching(tester);
    expect(find.byType(BoardEditorWidget), findsNothing);
    final filters = tester
        .widget<HeaderFilters>(find.byType(HeaderFilters))
        .controller;
    expect(filters.positionFen, contains('4P3'));
    expect(find.text('Show 1 game'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact workspace keeps apply and reset visible with many rows',
    (tester) async {
      await _open(
        tester,
        size: const Size(680, 480),
        initialConfig: SliceConfig(
          headerFilters: List.generate(
            12,
            (_) => const HeaderFilterConfig(
              field: 'Date',
              mode: MatchMode.after,
              value: '1971',
            ),
          ),
        ),
      );
      await _finishMatching(tester);
      expect(find.text('Clear filters').hitTestable(), findsOneWidget);
      expect(_apply.hitTestable(), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Show 2 games'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
