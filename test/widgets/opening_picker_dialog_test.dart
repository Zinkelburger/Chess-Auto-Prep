import 'package:chess_auto_prep/services/opening_catalog.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/opening_picker_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _openings = [
  CatalogOpening(eco: 'B00', name: 'King pawn', moves: ['e4']),
  CatalogOpening(eco: 'B00', name: 'Alekhine', moves: ['e4', 'Nf6']),
  CatalogOpening(eco: 'D00', name: 'Queen pawn', moves: ['d4']),
];

Future<void> _open(
  WidgetTester tester,
  ValueChanged<OpeningSelection?> done, {
  bool filters = false,
  Size size = const Size(1200, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => done(
              await showDialog<OpeningSelection>(
                context: context,
                builder: (_) => OpeningPickerDialog(
                  forFilters: filters,
                  openings: Future.value(_openings),
                ),
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

void main() {
  testWidgets(
    'searches names/codes, retains selections and edited moves across searches',
    (tester) async {
      OpeningSelection? result;
      await _open(tester, (value) => result = value);
      await tester.enterText(
        find.byKey(const ValueKey('opening-search')),
        'b00',
      );
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('opening-moves')),
        '1.e4 c5',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChessBoardWidget>(find.byType(ChessBoardWidget))
            .position
            .fen,
        contains('2p5'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('opening-search')),
        'queen',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add starting lines (2)'));
      await tester.pumpAndSettle();
      expect(result!.lines.map((e) => e.eco), ['B00', 'D00']);
      expect(result!.lines.first.moves, ['e4', 'c5']);
    },
  );

  testWidgets(
    'clearing the shared search restores results and keeps selection',
    (tester) async {
      OpeningSelection? result;
      await _open(tester, (value) => result = value, filters: true);
      await tester.enterText(
        find.byKey(const ValueKey('opening-search')),
        'queen',
      );
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(3));
      await tester.tap(find.text('Filter by selected ECO codes (1)'));
      await tester.pumpAndSettle();
      expect(result!.lines.single.eco, 'D00');
    },
  );

  testWidgets('invalid edits cannot become builder starts', (tester) async {
    OpeningSelection? result;
    await _open(tester, (value) => result = value);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('opening-moves')),
      '1.e4 e4',
    );
    await tester.tap(find.text('Add starting lines (1)'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Illegal move: e4'), findsOneWidget);
    await tester.tap(find.text('Reset line'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add starting lines (1)'));
    await tester.pumpAndSettle();
    expect(result!.lines.single.moves, ['e4']);
  });

  testWidgets(
    'position action uses edited preview without requiring a code selection',
    (tester) async {
      OpeningSelection? result;
      await _open(
        tester,
        (value) => result = value,
        filters: true,
        size: const Size(650, 900),
      );
      await tester.tap(find.text('B00 · King pawn'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('opening-moves'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '1.e4 c5');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use preview position'));
      await tester.pumpAndSettle();
      expect(result!.positionLine!.moves, ['e4', 'c5']);
      expect(result!.lines, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('code action retains original codes after preview edits', (
    tester,
  ) async {
    OpeningSelection? result;
    await _open(tester, (value) => result = value, filters: true);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('opening-moves')), '1.d4');
    await tester.tap(find.text('Filter by selected ECO codes (1)'));
    await tester.pumpAndSettle();
    expect(result!.lines.single.eco, 'B00');
    expect(result!.positionLine, isNull);
  });

  test(
    'bundled catalog preserves separate named lines for each code',
    () async {
      final lines = await OpeningCatalog.load();
      expect(lines.length, greaterThan(1000));
      expect(lines.where((line) => line.eco == 'B90').length, greaterThan(1));
      expect(lines.first.position.fen, isNotEmpty);
    },
  );
}
