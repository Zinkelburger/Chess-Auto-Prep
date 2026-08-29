import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/widgets/opening_explorer/explorer_move_row.dart';

const _e4 = ExplorerMove(
  san: 'e4',
  uci: 'e2e4',
  white: 50,
  draws: 30,
  black: 20,
  playRate: 45.4,
);
const _d4 = ExplorerMove(
  san: 'd4',
  uci: 'd2d4',
  white: 40,
  draws: 40,
  black: 20,
  playRate: 30.1,
);

Widget _host(List<Widget> rows) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 340,
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      ),
    ),
  ),
);

Future<TestGesture> _mouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  return gesture;
}

void main() {
  testWidgets('hovering tints a row without changing any row size', (
    tester,
  ) async {
    final hovers = <bool>[];
    await tester.pumpWidget(
      _host([
        ExplorerMoveRow(move: _e4, onPlay: () {}, onHover: hovers.add),
        ExplorerMoveRow(move: _d4, onPlay: () {}, onAdd: () {}),
      ]),
    );

    final rows = find.byType(ExplorerMoveRow);
    final before = tester.getSize(rows.at(0));
    final d4Before = tester.getTopLeft(rows.at(1));

    final mouse = await _mouse(tester);
    await mouse.moveTo(tester.getCenter(rows.at(0)));
    await tester.pumpAndSettle();
    expect(hovers, [true]);
    expect(tester.getSize(rows.at(0)), before);
    expect(tester.getSize(rows.at(0)).height, ExplorerColumns.rowHeight);
    // The row beneath did not move: nothing grew under the pointer.
    expect(tester.getTopLeft(rows.at(1)), d4Before);

    await mouse.moveTo(tester.getCenter(rows.at(1)));
    await tester.pumpAndSettle();
    expect(hovers, [true, false]);
  });

  testWidgets('clicking a row plays the move; no "+" button is rendered', (
    tester,
  ) async {
    var played = 0;
    await tester.pumpWidget(
      _host([ExplorerMoveRow(move: _e4, onPlay: () => played++, onAdd: () {})]),
    );
    expect(find.byIcon(Icons.add), findsNothing);

    await tester.tap(find.text('e4'));
    expect(played, 1);
  });

  testWidgets('shows games, share of the position and bar percentages', (
    tester,
  ) async {
    await tester.pumpWidget(_host([ExplorerMoveRow(move: _e4, onPlay: () {})]));

    expect(find.text('100'), findsOneWidget); // games with the move
    expect(find.text('45%'), findsOneWidget); // share of the position
    // White / draw / black inside the bar segments.
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('30%'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);
  });

  testWidgets('right-click offers "add to repertoire" when the host can', (
    tester,
  ) async {
    var added = 0;
    await tester.pumpWidget(
      _host([ExplorerMoveRow(move: _e4, onPlay: () {}, onAdd: () => added++)]),
    );

    await tester.tapAt(
      tester.getCenter(find.text('e4')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Add e4 to repertoire'), findsOneWidget);

    await tester.tap(find.text('Add e4 to repertoire'));
    await tester.pumpAndSettle();
    expect(added, 1);
  });

  testWidgets('a move already in the repertoire is marked, not re-offered', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        ExplorerMoveRow(
          move: _e4,
          onPlay: () {},
          onAdd: () {},
          inRepertoire: true,
        ),
      ]),
    );
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tapAt(
      tester.getCenter(find.text('e4')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('e4 is already in the repertoire'), findsOneWidget);
  });

  testWidgets('the Σ row totals every game from the position', (tester) async {
    const response = ExplorerResponse(
      fen: 'x',
      moves: [_e4, _d4],
      totalGames: 200,
    );
    await tester.pumpWidget(
      _host(const [
        ExplorerTableHeader(),
        ExplorerTotalsRow(response: response),
      ]),
    );

    expect(find.text('Move'), findsOneWidget);
    expect(find.text('Games'), findsOneWidget);
    expect(find.text('Σ'), findsOneWidget);
    expect(find.text('200'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    // (50+40)/200, (30+40)/200, (20+20)/200
    expect(find.text('45%'), findsOneWidget);
    expect(find.text('35%'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);
  });
}
