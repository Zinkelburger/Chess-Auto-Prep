import 'package:chess_auto_prep/widgets/lines_preview_panel.dart';
import 'package:chess_auto_prep/widgets/pgn_slice_dialog.dart';
import 'package:chess_auto_prep/widgets/slice/header_filters.dart';
import 'package:chess_auto_prep/widgets/slice/sequence_filter.dart';
import 'package:chess_auto_prep/widgets/slice/position_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
const _games = <GameRecord>[
  (
    headers: {'White': 'Alpha', 'Black': 'Beta', 'Date': '2025.01.01'},
    pgnText: '1. e4 e5 *',
  ),
  (
    headers: {'White': 'Gamma', 'Black': 'Delta', 'Date': '2026.01.01'},
    pgnText: '1. d4 d5 *',
  ),
];

Future<void> _open(
  WidgetTester tester, {
  SliceApplyCallback? onApply,
  SliceConfig? initialConfig,
  Size size = const Size(1200, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => PgnSliceDialog(
                allGames: _games,
                initialConfig: initialConfig,
                currentFen: _fen,
                collectionName: 'Practice.pgn',
                onApply: onApply ?? (_, _) {},
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Finder get _value => find
    .descendant(
      of: find.byType(HeaderFilters),
      matching: find.byType(TextField),
    )
    .last;

Future<void> _finishMatching(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 350));
  // Matching uses a real isolate; allow it to reply outside fake async.
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'starts focused on filters, with optional preview and advanced moves',
    (tester) async {
      await _open(tester);
      expect(find.text('Practice.pgn · 2 games'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(PositionFilter), findsNothing);
      expect(find.text('Cancel'), findsNothing);
      expect(find.text('Board position or move sequence'), findsNothing);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('pgn-filter-dialog-content')))
            .height,
        lessThanOrEqualTo(672),
      );
      expect(find.byType(LinesPreviewPanel), findsNothing);
      expect(find.byType(SequenceFilter), findsNothing);
      expect(find.text('Preview games'), findsNothing);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Show 2 games'), findsOneWidget);

      await tester.tap(find.text('Year'));
      await tester.pumpAndSettle();
      await tester.enterText(_value, '2026');
      await _finishMatching(tester);
      expect(find.text('Date contains'), findsOneWidget);
      expect(find.text('Match all conditions'), findsNothing);
      expect(find.text('Show 1 game'), findsOneWidget);
      expect(find.byType(LinesPreviewPanel), findsNothing);
      await tester.ensureVisible(find.text('Preview games'));
      await tester.tap(find.text('Preview games'));
      await tester.pumpAndSettle();
      expect(find.byType(LinesPreviewPanel), findsOneWidget);
      expect(find.text('Hide preview').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.byType(LinesPreviewPanel), findsNothing);
      expect(find.text('Show 2 games'), findsOneWidget);
      await tester.ensureVisible(find.text('Position & moves'));
      await tester.tap(find.text('Position & moves'));
      await tester.pumpAndSettle();
      expect(find.byType(SequenceFilter), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cannot apply old results during debounce or invalid position input',
    (tester) async {
      List<int>? applied;
      await _open(tester, onApply: (indices, _) => applied = indices);
      await tester.tap(find.text('Year'));
      await tester.pumpAndSettle();
      await tester.enterText(_value, '202');
      await _finishMatching(tester);
      expect(find.text('Show 2 games'), findsOneWidget);
      await tester.enterText(_value, '2026');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await _finishMatching(tester);
      expect(find.text('Show 1 game'), findsOneWidget);
      await tester.tap(find.text('Position & moves'));
      await tester.pumpAndSettle();
      final position = find.widgetWithText(TextField, 'FEN or moves');
      await tester.enterText(position, 'invalid');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.enterText(position, '');
      await _finishMatching(tester);
      await tester.tap(find.text('Show 1 game'));
      await tester.pumpAndSettle();
      expect(applied, [1]);
      expect(find.byType(PgnSliceDialog), findsNothing);
    },
  );

  testWidgets('saved conditions stay editable in a compact desktop dialog', (
    tester,
  ) async {
    SliceConfig? applied;
    await _open(
      tester,
      size: const Size(680, 720),
      initialConfig: const SliceConfig(
        headerFilters: [
          HeaderFilterConfig(
            field: 'Date',
            mode: MatchMode.after,
            value: '2025',
          ),
        ],
      ),
      onApply: (_, config) => applied = config,
    );
    await _finishMatching(tester);
    expect(find.text('In or after'), findsOneWidget);
    final dialogSize = tester.getSize(
      find.byKey(const ValueKey('pgn-filter-dialog-content')),
    );
    expect(dialogSize.width, lessThanOrEqualTo(560));
    expect(dialogSize.height, lessThanOrEqualTo(672));
    expect(find.text('Match all conditions'), findsNothing);
    await tester.enterText(_value, '2026');
    await _finishMatching(tester);
    await tester.tap(find.text('Show 1 game'));
    await tester.pumpAndSettle();
    expect(applied!.headerFilters.single.value, '2026');
    expect(applied!.headerFilters.single.mode, MatchMode.after);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Clear filters stays visible when many conditions need scrolling',
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
              value: '2025',
            ),
          ),
        ),
      );
      expect(find.text('Match all conditions'), findsOneWidget);
      expect(find.text('Clear filters').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Choose condition'), findsNothing);
      expect(find.text('Year').hitTestable(), findsOneWidget);
      expect(find.text('Show 2 games'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
