import 'package:chess_auto_prep/widgets/lines_preview_panel.dart';
import 'package:chess_auto_prep/widgets/pgn_slice_dialog.dart';
import 'package:chess_auto_prep/widgets/slice/header_filters.dart';
import 'package:chess_auto_prep/widgets/slice/sequence_filter.dart';
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

Future<void> _open(WidgetTester tester, {SliceApplyCallback? onApply}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
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
      expect(find.textContaining('Filter for: choose'), findsOneWidget);
      expect(find.byType(LinesPreviewPanel), findsNothing);
      expect(find.byType(SequenceFilter), findsNothing);
      expect(find.text('Preview matching games'), findsNothing);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Show 2 games'), findsOneWidget);

      await tester.enterText(_value, '2026');
      await _finishMatching(tester);
      expect(find.textContaining('Filter for: Date'), findsOneWidget);
      expect(find.text('Show 1 game'), findsOneWidget);
      expect(find.byType(LinesPreviewPanel), findsNothing);
      await tester.ensureVisible(find.text('Preview matching games'));
      await tester.tap(find.text('Preview matching games'));
      await tester.pumpAndSettle();
      expect(find.byType(LinesPreviewPanel), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.byType(LinesPreviewPanel), findsNothing);
      expect(find.text('Show 2 games'), findsOneWidget);
      await tester.ensureVisible(find.text('Advanced'));
      await tester.tap(find.text('Advanced'));
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
      await tester.enterText(_value, '2025');
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
}
