/// The FICS archive block is the app's opening-explorer table with the book
/// behind it: shut by default with a one-line summary, twelve rows at most,
/// a seat letter before each move, a Σ row, a one-line tooltip, and hover
/// that draws on the boards without moving a single row.
library;

import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_book.dart';
import 'package:chess_auto_prep/features/bughouse/widgets/bughouse_book_panel.dart';
import 'package:chess_auto_prep/widgets/opening_explorer/explorer_move_row.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_bughouse_engine.dart';

const _status = BughouseBookStatus(
  path: 'canned',
  games: 3600000,
  maxPly: 16,
  minGames: 3,
  years: [2005, 2025],
);

BughouseBookMove _move(
  BughouseBoard board,
  String san, {
  required int games,
  int? elo = 1900,
}) => BughouseBookMove(
  board: board,
  mover: Side.white,
  san: san,
  games: games,
  teamA: games ~/ 2,
  teamB: games ~/ 4,
  draws: games ~/ 10,
  unknown: games - games ~/ 2 - games ~/ 4 - games ~/ 10,
  averageElo: elo,
  maxElo: 2400,
  lastYear: 2025,
  topGameNo: 7,
);

/// Fourteen rarer first moves, so the start has more than the table lists.
const _tail = [
  'a3', 'a4', 'b3', 'b4', 'c3', 'c4', 'd3', //
  'e3', 'f3', 'f4', 'g3', 'g4', 'h3', 'h4',
];

/// The starting position with more continuations than the table lists, and
/// the position after 1A. e4 with one; everything else is off the book.
BughouseBookPosition _lookup(String fenA, String fenB) {
  final start = BughouseState.initial();
  if (fenA == start.boardA.fen && fenB == start.boardB.fen) {
    return BughouseBookPosition(
      key: 1,
      games: 2000,
      teamA: 1000,
      teamB: 600,
      draws: 100,
      unknown: 300,
      moves: [
        _move(BughouseBoard.a, 'e4', games: 1000),
        _move(BughouseBoard.b, 'd4', games: 400),
        for (final (i, san) in _tail.indexed)
          _move(BughouseBoard.a, san, games: 20 - i, elo: null),
      ],
    );
  }
  if (fenA.startsWith('rnbqkbnr/pppppppp/8/8/4P3') &&
      fenB == start.boardB.fen) {
    return BughouseBookPosition(
      key: 2,
      games: 900,
      teamA: 500,
      teamB: 300,
      draws: 50,
      unknown: 50,
      moves: [_move(BughouseBoard.a, 'e5', games: 900)],
    );
  }
  return BughouseBookPosition.empty;
}

void main() {
  late BughouseController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = BughouseController(
      engineOverride: FakeBughouseEngine(),
      bookOverride: BughouseBook.canned(status: _status, lookup: _lookup),
    );
    controller.setAnalysisEnabled(false);
  });

  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: ListenableBuilder(
                listenable: controller,
                builder: (_, _) => BughouseBookPanel(controller: controller),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<TestGesture> mouse(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    return gesture;
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('FICS ARCHIVE'));
    await tester.pumpAndSettle();
  }

  testWidgets('known positions retain counts when continuations are filtered', (
    tester,
  ) async {
    controller.dispose();
    controller = BughouseController(
      engineOverride: FakeBughouseEngine(),
      bookOverride: BughouseBook.canned(
        status: _status,
        lookup: (_, _) => const BughouseBookPosition(
          key: 4,
          games: 4,
          teamA: 0,
          teamB: 4,
          draws: 0,
          unknown: 0,
          moves: [],
        ),
      ),
    );
    controller.setAnalysisEnabled(false);
    await pump(tester);
    expect(find.text('4 games here · 2005–2025'), findsOneWidget);
    expect(find.text('No archived game reached this position.'), findsNothing);
    await open(tester);
    expect(
      find.textContaining(
        'No continuations meet the archive minimum of 3 games',
      ),
      findsOneWidget,
    );
  });

  testWidgets('starts shut, with the position summed up in one line', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('FICS ARCHIVE'), findsOneWidget);
    expect(find.text('2.0k games here · 2005–2025'), findsOneWidget);
    expect(find.byType(ExplorerMoveRow), findsNothing);
    expect(find.text('Move'), findsNothing);

    await open(tester);
    expect(find.byType(ExplorerMoveRow), findsWidgets);

    await tester.tap(find.text('FICS ARCHIVE'));
    await tester.pumpAndSettle();
    expect(find.byType(ExplorerMoveRow), findsNothing);
  });

  testWidgets('is the explorer table: captions, seats, a cap and a Σ row', (
    tester,
  ) async {
    await pump(tester);
    await open(tester);

    expect(find.text('Move'), findsOneWidget);
    expect(find.text('Win / Draw / Loss'), findsOneWidget);
    expect(find.byType(ExplorerTableHeader), findsOneWidget);
    // 16 continuations in the book, 12 listed — the Lichess explorer's cap.
    expect(
      find.byType(ExplorerMoveRow),
      findsNWidgets(BughouseBookPanel.maxRows),
    );
    expect(find.text('a3'), findsOneWidget);
    expect(find.text('f4'), findsOneWidget);
    expect(find.text('g3'), findsNothing);

    // Seat letters, not board letters: White on board 1 is us (A); White on
    // board 2 is our partner's opponent (D).
    expect(find.text('e4'), findsOneWidget);
    expect(find.text('d4'), findsOneWidget);
    expect(find.text('A'), findsWidgets);
    expect(find.text('D'), findsOneWidget);

    // 1000 of 2000 games; the Σ row counts every game, listed or not.
    expect(find.text('1.0k'), findsOneWidget);
    expect(find.text('50%'), findsWidgets);
    expect(find.text('Σ'), findsOneWidget);
    expect(find.text('2.0k'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.byType(ExplorerTotalsRow), findsOneWidget);
  });

  testWidgets('hover says one thing, and draws on the boards without moving', (
    tester,
  ) async {
    await pump(tester);
    await open(tester);

    final rows = find.byType(ExplorerMoveRow);
    final e4 = rows.at(0);
    final d4 = rows.at(1);
    final e4Size = tester.getSize(e4);
    final d4Top = tester.getTopLeft(d4);

    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: find.text('e4'), matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, 'Average rating: 1900');
    expect(tooltip.message, isNot(contains('\n')));

    final pointer = await mouse(tester);
    await pointer.moveTo(tester.getCenter(e4));
    await tester.pumpAndSettle();
    expect(controller.hover.value, isNotNull);
    expect(controller.hover.value!.on(BughouseBoard.a), isNotEmpty);
    expect(tester.getSize(e4), e4Size);
    expect(tester.getSize(e4).height, ExplorerColumns.rowHeight);
    expect(tester.getTopLeft(d4), d4Top);

    await pointer.moveTo(tester.getCenter(d4));
    await tester.pumpAndSettle();
    expect(controller.hover.value!.on(BughouseBoard.b), isNotEmpty);
    expect(controller.hover.value!.on(BughouseBoard.a), isEmpty);

    await pointer.moveTo(const Offset(390, 5));
    await tester.pumpAndSettle();
    expect(controller.hover.value, isNull);
  });

  testWidgets('clicking a row plays it, and the table follows the position', (
    tester,
  ) async {
    await pump(tester);
    await open(tester);

    final pointer = await mouse(tester);
    await pointer.moveTo(tester.getCenter(find.text('e4')));
    await tester.pumpAndSettle();
    expect(controller.hover.value, isNotNull);

    await tester.tap(find.text('e4'));
    await tester.pumpAndSettle();

    expect(controller.history.cursor, 1);
    expect(
      controller.state.boardA.fen,
      startsWith('rnbqkbnr/pppppppp/8/8/4P3'),
    );
    // The rows under the pointer were replaced. The old row's highlight went
    // with it, and the pointer now rests on the new first row, so the boards
    // show that one — not a stale e4.
    final drawn = controller.hover.value!.on(BughouseBoard.a);
    expect(drawn.map((a) => a.dest), contains('e5'));
    expect(drawn.map((a) => a.dest), isNot(contains('e4')));
    expect(find.text('900 games here · 2005–2025'), findsOneWidget);
    expect(find.text('e5'), findsOneWidget);
    expect(find.text('d4'), findsNothing);
    expect(find.byType(ExplorerMoveRow), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pointer.moveTo(const Offset(390, 5));
    await tester.pumpAndSettle();
    expect(controller.hover.value, isNull);
  });

  testWidgets('off the book, the summary says so and the table is a message', (
    tester,
  ) async {
    await pump(tester);
    controller.playMove(BughouseBoard.b, Move.parse('d2d4')!);
    await tester.pumpAndSettle();

    expect(
      find.text('No archived game reached this position.'),
      findsOneWidget,
    );
    await open(tester);
    expect(
      find.text('No archived game reached this position.'),
      findsNWidgets(2),
    );
    expect(find.byType(ExplorerMoveRow), findsNothing);
    expect(find.byType(ExplorerTotalsRow), findsNothing);
  });
}
