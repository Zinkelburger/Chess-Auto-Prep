import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_settings_body.dart';
import 'package:chess_auto_prep/models/board_size.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('side requires Apply while board size changes immediately', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var white = true;
    var boardSize = BoardSize.large;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, refresh) => ListView(
              children: [
                RepertoireSettingsBody(
                  isWhiteRepertoire: white,
                  boardSize: boardSize,
                  onSideChanged: (value) => refresh(() => white = value),
                  onBoardSizeChanged: (value) =>
                      refresh(() => boardSize = value),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Black'));
    await tester.pumpAndSettle();
    expect(white, isTrue);
    await tester.tap(find.text('Apply playing side'));
    await tester.pumpAndSettle();
    expect(white, isFalse);
    expect(find.byType(RepertoireSettingsBody), findsOneWidget);
    await tester.tap(find.text('Small'));
    await tester.pumpAndSettle();
    expect(boardSize, BoardSize.small);
    expect(tester.takeException(), isNull);
  });

  testWidgets('generation locks the side and still permits layout changes', (
    tester,
  ) async {
    var sideChanges = 0;
    var boardSize = BoardSize.large;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              RepertoireSettingsBody(
                isWhiteRepertoire: true,
                boardSize: boardSize,
                sideChangeEnabled: false,
                onSideChanged: (_) => sideChanges++,
                onBoardSizeChanged: (value) => boardSize = value,
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
          .onSelectionChanged,
      isNull,
    );
    await tester.tap(find.text('Small'));
    await tester.pumpAndSettle();
    expect(boardSize, BoardSize.small);
    expect(sideChanges, 0);
    expect(tester.takeException(), isNull);
  });
}
