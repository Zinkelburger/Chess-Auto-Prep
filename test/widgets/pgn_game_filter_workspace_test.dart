import 'package:chess_auto_prep/services/opening_catalog.dart';
import 'package:chess_auto_prep/core/board_editor_controller.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/widgets/board_editor/board_editor_widget.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_tree_games_list.dart';
import 'package:chess_auto_prep/widgets/layout/responsive_split_layout.dart';
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
  void Function(List<int>, SliceConfig, int)? onOpenGame,
  SliceConfig? initialConfig,
  List<GameRecord> games = _games,
  String? collectionPlayer,
  Size size = const Size(1280, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: PgnGameFilterWorkspace(
          allGames: games,
          collectionPlayer: collectionPlayer,
          initialConfig: initialConfig,
          currentFen: _fen,
          collectionName: 'Practice.pgn',
          onApply: onApply ?? (_, _) {},
          onOpenGame: onOpenGame,
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

Future<void> _chooseField(WidgetTester tester, String field) async {
  final input = find
      .byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Search…',
      )
      .last;
  await tester.ensureVisible(input);
  await tester.enterText(input, field);
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(CompositedTransformFollower),
      matching: find.text(field),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('starts with one blank row and keeps results and apply visible', (
    tester,
  ) async {
    await _open(tester, size: const Size(680, 480));
    final controller = tester
        .widget<HeaderFilters>(find.byType(HeaderFilters))
        .controller;
    expect(controller.headerRows, hasLength(1));
    expect(controller.headerRows.single.field, isEmpty);
    expect(controller.buildConfig().isEmpty, isTrue);
    expect(find.byType(PgnTreeGamesList), findsOneWidget);
    expect(
      find.textContaining('Fischer vs Spassky').hitTestable(),
      findsOneWidget,
    );
    expect(_apply.hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Remove filter'));
    await tester.pumpAndSettle();
    expect(controller.headerRows, hasLength(1));
    expect(controller.headerRows.single.field, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'multiple positions switch AND to OR and open the correct result',
    (tester) async {
      SliceConfig? applied;
      int? opened;
      await _open(
        tester,
        onApply: (_, config) => applied = config,
        onOpenGame: (_, _, index) => opened = index,
      );
      await tester.tap(find.text('Positions'));
      await tester.pumpAndSettle();
      final positions = find.widgetWithText(TextField, 'FEN or moves');
      await tester.ensureVisible(positions.first);
      await tester.enterText(positions.first, '1. e4');
      await _finishMatching(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('add-position')));
      await tester.tap(find.byKey(const ValueKey('add-position')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(positions.last);
      await tester.enterText(positions.last, '1. d4');
      FocusManager.instance.primaryFocus?.unfocus();
      await _finishMatching(tester);
      expect(find.text('No games match'), findsOneWidget);
      final logic = find.byKey(const ValueKey('filter-logic'));
      await tester.ensureVisible(logic);
      await tester.enterText(logic, 'OR');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(CompositedTransformFollower),
          matching: find.text('OR'),
        ),
      );
      await _finishMatching(tester);
      expect(find.text('Show 2 games'), findsOneWidget);
      await tester.tap(find.textContaining('Spassky vs Fischer'));
      await tester.pumpAndSettle();
      expect(opened, 1);
      await tester.tap(_apply);
      await tester.pumpAndSettle();
      expect(applied!.matchAny, isTrue);
      expect(applied!.additionalPositions, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'conditions combine with a user-entered position using the app theme',
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
      expect(find.byType(PgnTreeGamesList), findsOneWidget);
      expect(
        tester
            .widget<PgnTreeGamesList>(find.byType(PgnTreeGamesList))
            .initiallyShowMoves,
        isFalse,
      );
      expect(find.text('King’s Indian'), findsNothing);
      expect(
        Theme.of(tester.element(find.byType(HeaderFilters))).brightness,
        Brightness.dark,
      );
      await _chooseField(tester, 'Player');
      await _finishMatching(tester);
      final controller = tester
          .widget<HeaderFilters>(find.byType(HeaderFilters))
          .controller;
      controller.setHeaderField(0, 'Black');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              identical(
                widget.controller,
                controller.headerRows.single.controller,
              ),
        ),
        'Fischer',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await _finishMatching(tester);
      expect(controller.headerRows.single.field, 'Black');
      expect(controller.headerRows.single.controller.text, 'Fischer');
      expect(find.text('Show 1 game'), findsOneWidget);
      await tester.tap(find.text('Positions'));
      await tester.pumpAndSettle();
      final position = find.widgetWithText(TextField, 'FEN or moves');
      await tester.ensureVisible(position);
      await tester.enterText(
        position,
        '1. d4 Nf6 2. c4 g6 3. Nc3 Bg7 4. e4 d6',
      );
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

  testWidgets('catalog picks match either code and preserve other conditions', (
    tester,
  ) async {
    await tester.runAsync(OpeningCatalog.load);
    List<int>? applied;
    await _open(
      tester,
      games: [
        (
          headers: {..._games[0].headers, 'ECO': 'B00'},
          pgnText: _games[0].pgnText,
        ),
        (
          headers: {..._games[1].headers, 'ECO': 'D00'},
          pgnText: _games[1].pgnText,
        ),
        (
          headers: {..._games[0].headers, 'ECO': 'C20'},
          pgnText: _games[0].pgnText,
        ),
      ],
      initialConfig: const SliceConfig(
        headerFilters: [
          HeaderFilterConfig(field: 'ECO', value: 'C20', mode: MatchMode.exact),
          HeaderFilterConfig(
            field: 'White',
            value: 'Fischer',
            mode: MatchMode.exact,
          ),
        ],
      ),
      onApply: (indices, _) => applied = indices,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('filter-choose-eco')));
    await tester.tap(find.byKey(const ValueKey('filter-choose-eco')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    // The existing code remains selected when the picker reopens.
    expect(find.text('Filter by selected ECO codes (1)'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('opening-search')), 'C20');
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Checkbox))
          .first,
    );
    await tester.pumpAndSettle();
    for (final code in ['B00', 'D00']) {
      await tester.enterText(
        find.byKey(const ValueKey('opening-search')),
        code,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(Checkbox),
            )
            .first,
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Filter by selected ECO codes (2)'));
    await _finishMatching(tester);
    await tester.tap(_apply);
    expect(applied, [0]);
    final controller = tester
        .widget<HeaderFilters>(find.byType(HeaderFilters))
        .controller;
    expect(controller.headerRows.length, 2);
    controller.removeHeaderRow(0);
    await _finishMatching(tester);
    await tester.tap(_apply);
    expect(applied, [0, 1]);
    expect(find.widgetWithText(InputChip, 'B00'), findsOneWidget);
    final chip = tester.widget<InputChip>(
      find.widgetWithText(InputChip, 'B00'),
    );
    chip.onDeleted!();
    await _finishMatching(tester);
    await tester.tap(_apply);
    expect(applied, [1]);
    expect(controller.headerRows.single.value, 'D00');
    expect(controller.headerRows.single.controller.text, 'D00');
    expect(controller.headerRows.single.mode, MatchMode.exact);
  });

  testWidgets(
    'direct filters add ECO prefix search and dates default to After',
    (tester) async {
      List<int>? applied;
      await _open(
        tester,
        games: [
          (
            headers: {..._games[0].headers, 'ECO': 'C20'},
            pgnText: _games[0].pgnText,
          ),
          (
            headers: {..._games[1].headers, 'ECO': 'E60'},
            pgnText: _games[1].pgnText,
          ),
        ],
        onApply: (indices, _) => applied = indices,
      );
      expect(find.byKey(const ValueKey('add-filter-row')), findsOneWidget);
      expect(find.text('More…'), findsNothing);
      await _chooseField(tester, 'ECO');
      await tester.pumpAndSettle();
      final controller = tester
          .widget<HeaderFilters>(find.byType(HeaderFilters))
          .controller;
      final input = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            identical(
              widget.controller,
              controller.headerRows.single.controller,
            ),
      );
      await tester.enterText(input, 'E');
      FocusManager.instance.primaryFocus?.unfocus();
      await _finishMatching(tester);
      await tester.tap(_apply);
      expect(applied, [1]);
      await tester.tap(find.byKey(const ValueKey('add-filter-row')));
      await tester.pumpAndSettle();
      await _chooseField(tester, 'Date');
      await tester.pumpAndSettle();
      expect(controller.headerRows.last.field, 'Date');
      expect(controller.headerRows.last.mode, MatchMode.after);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('one player per field; comma-separated PGN names stay valid', (
    tester,
  ) async {
    await _open(tester);
    await _chooseField(tester, 'Player');
    await tester.pumpAndSettle();
    final controller = tester
        .widget<HeaderFilters>(find.byType(HeaderFilters))
        .controller;
    final input = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          identical(widget.controller, controller.headerRows.single.controller),
    );
    await tester.enterText(input, 'Fischer; Spassky');
    await tester.pumpAndSettle();
    expect(find.text('Use one player name per filter'), findsOneWidget);
    expect(tester.widget<FilledButton>(_apply).onPressed, isNull);
    await tester.enterText(input, 'Fischer, Robert');
    await _finishMatching(tester);
    expect(find.text('Use one player name per filter'), findsNothing);
    expect(controller.headerRows.single.hasMultiplePlayerNames, isFalse);
    expect(find.text('Positions'), findsOneWidget);
    expect(find.text('Add condition'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
    expect(find.byType(PgnTreeGamesList), findsNothing);
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
    await tester.tap(find.text('Positions'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('position-source')));
    await tester.tap(find.byKey(const ValueKey('position-source')));
    await tester.pumpAndSettle();
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

  testWidgets('draft survives tab switches beside the board', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var searching = true;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            appBar: AppBar(
              actions: [
                TextButton(
                  onPressed: () => setState(() => searching = !searching),
                  child: const Text('Switch tab'),
                ),
              ],
            ),
            body: ResponsiveSplitLayout(
              primary: const Center(child: Text('Game board')),
              secondary: IndexedStack(
                index: searching ? 1 : 0,
                children: [
                  const Text('Game reader'),
                  PgnGameFilterWorkspace(
                    allGames: _games,
                    currentFen: _fen,
                    onApply: (_, _) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _finishMatching(tester);
    final controller = tester
        .widget<HeaderFilters>(find.byType(HeaderFilters))
        .controller;
    controller.addHeaderRow();
    controller.setHeaderField(0, 'Black');
    controller.setHeaderValue(0, 'Fischer');
    await _finishMatching(tester);
    await tester.tap(find.text('Switch tab'));
    await tester.pumpAndSettle();
    expect(find.text('Game reader'), findsOneWidget);
    await tester.tap(find.text('Switch tab'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<HeaderFilters>(find.byType(HeaderFilters)).controller,
      same(controller),
    );
    expect(controller.headerConfigs.single.value, 'Fischer');
    expect(find.text('Show 1 game'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late saved filters refresh an untouched draft but preserve user edits',
    (tester) async {
      await _open(tester);
      const saved = SliceConfig(
        headerFilters: [
          HeaderFilterConfig(
            field: 'Black',
            mode: MatchMode.contains,
            value: 'Fischer',
          ),
        ],
      );
      await _open(tester, initialConfig: saved);
      await _finishMatching(tester);
      var controller = tester
          .widget<HeaderFilters>(find.byType(HeaderFilters))
          .controller;
      expect(controller.headerConfigs.single.value, 'Fischer');
      expect(find.text('Show 1 game'), findsOneWidget);
      controller.setHeaderValue(0, 'Spassky');
      await _finishMatching(tester);
      await _open(tester, initialConfig: const SliceConfig.empty());
      controller = tester
          .widget<HeaderFilters>(find.byType(HeaderFilters))
          .controller;
      expect(controller.headerConfigs.single.value, 'Spassky');
      expect(tester.takeException(), isNull);
    },
  );

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
