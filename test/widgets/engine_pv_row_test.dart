import 'package:chess_auto_prep/widgets/engine/engine_pv_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const longLine = [
    'e4',
    'e5',
    'Nf3',
    'Nc6',
    'Bb5',
    'a6',
    'Ba4',
    'Nf6',
    'O-O',
    'Be7',
    'Re1',
    'b5',
    'Bb3',
    'd6',
  ];

  testWidgets('expanded PV scrolls to later moves without resizing', (
    tester,
  ) async {
    final moves = List.generate(100, (i) => i.isEven ? 'Nf3' : 'Nc6');
    int? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: EnginePvRow(
              evaluation: '+0.20',
              sanMoves: moves,
              startPly: 0,
              onMoveTapped: (index) => tapped = index,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Show full line'));
    await tester.pumpAndSettle();
    final expandedHeight = tester.getSize(find.byType(EnginePvRow)).height;
    final lastMove = find.text('Nc6').last;
    await tester.scrollUntilVisible(
      lastMove,
      100,
      scrollable: find.byType(Scrollable),
    );
    await tester.tap(lastMove);
    expect(tapped, 99);
    expect(tester.getSize(find.byType(EnginePvRow)).height, expandedHeight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('move numbers and separator padding preview the same move', (
    tester,
  ) async {
    int? hovered;
    int? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: EnginePvRow(
              evaluation: '+0.20',
              sanMoves: const ['e4', 'e5', 'Nf3'],
              startPly: 0,
              onMoveHovered: (index, _) => hovered = index,
              onHoverExit: () => hovered = null,
              onMoveTapped: (index) => tapped = index,
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('1.')));
    await tester.pump();
    expect(hovered, 0);
    final label = tester.getRect(find.text('e4'));
    await mouse.moveTo(Offset(label.right + 4, label.center.dy));
    await tester.pump();
    expect(hovered, 0);
    await tester.tapAt(Offset(label.right + 4, label.center.dy));
    expect(tapped, 0);
    await mouse.moveTo(tester.getCenter(find.text('e5')));
    await tester.pump();
    expect(hovered, 1);
    await mouse.removePointer();
  });

  for (final textScale in [1.0, 1.5, 2.0]) {
    testWidgets('PV stays fixed across updates at text scale $textScale', (
      tester,
    ) async {
      Widget viewer(List<String> moves) => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: Column(
              children: [
                EnginePvRow(
                  evaluation: '+0.20',
                  sanMoves: moves,
                  startPly: 0,
                  onMoveTapped: (_) {},
                ),
                const Text('Next engine line'),
              ],
            ),
          ),
        ),
      );
      double nextTop() => tester.getTopLeft(find.text('Next engine line')).dy;
      await tester.pumpWidget(viewer(['e4']));
      final compactTop = nextTop();
      await tester.pumpWidget(viewer(longLine));
      expect(nextTop(), compactTop);
      await tester.tap(find.byTooltip('Show full line'));
      await tester.pumpAndSettle();
      final expandedTop = nextTop();
      expect(expandedTop, greaterThan(compactTop));
      await tester.pumpWidget(viewer(['e4']));
      expect(nextTop(), expandedTop);
      // A shortened PV must still let the user close its expanded space.
      await tester.tap(find.byTooltip('Collapse line'));
      await tester.pumpAndSettle();
      expect(nextTop(), compactTop);
      expect(tester.takeException(), isNull);
    });
  }
}
