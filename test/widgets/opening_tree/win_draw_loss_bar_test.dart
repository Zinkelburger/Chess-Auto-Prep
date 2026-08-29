import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/widgets/opening_tree/win_draw_loss_bar.dart';

Widget _host(Widget bar, {double width = 200}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: bar),
    ),
  ),
);

void main() {
  testWidgets('labels every segment with its percentage', (tester) async {
    await tester.pumpWidget(
      _host(
        const WinDrawLossBar(
          wins: 60,
          draws: 25,
          losses: 15,
          perspective: WdlPerspective.whiteBlack,
          showPercentages: true,
        ),
      ),
    );
    expect(find.text('60%'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('15%'), findsOneWidget);
  });

  testWidgets('drops a label its segment cannot fit', (tester) async {
    await tester.pumpWidget(
      _host(
        const WinDrawLossBar(
          wins: 98,
          draws: 0,
          losses: 2,
          showPercentages: true,
        ),
        width: 100,
      ),
    );
    expect(find.text('98%'), findsOneWidget);
    expect(find.text('2%'), findsNothing); // 2px wide: no room, no overflow
    expect(tester.takeException(), isNull);
  });

  testWidgets('stays a plain bar without showPercentages', (tester) async {
    await tester.pumpWidget(
      _host(const WinDrawLossBar(wins: 1, draws: 1, losses: 1)),
    );
    expect(find.byType(Text), findsNothing);
  });

  test('percentOf rounds against the bar total', () {
    const bar = WinDrawLossBar(wins: 1, draws: 1, losses: 1);
    expect(bar.percentOf(1), 33);
    expect(const WinDrawLossBar(wins: 0, draws: 0, losses: 0).percentOf(0), 0);
  });
}
