import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_outline_controls.dart';

void main() {
  testWidgets('chapter strip keeps its width and expands on tap', (
    tester,
  ) async {
    var expanded = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              RepertoireOutlineStrip(onExpand: () => expanded++),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Chapters'), findsOneWidget);
    expect(find.byTooltip('Show chapters'), findsOneWidget);
    expect(tester.getSize(find.byType(RepertoireOutlineStrip)).width, 28);
    await tester.tap(find.text('Chapters'));
    expect(expanded, 1);
  });

  testWidgets('outline follows the pointer after either drag limit', (
    tester,
  ) async {
    var width = 280.0;
    var ended = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Row(
              children: [
                SizedBox(width: width),
                RepertoireOutlineResizeHandle(
                  currentWidth: width,
                  minWidth: 220,
                  maxWidth: 400,
                  onWidthChanged: (value) => setState(() => width = value),
                  onDragEnd: () => ended++,
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    final handle = find.byType(RepertoireOutlineResizeHandle);
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveTo(const Offset(600, 300));
    await tester.pump();
    expect(width, 400);
    await gesture.moveTo(const Offset(350, 300));
    await tester.pump();
    expect(width, closeTo(350, 0.1));
    await gesture.moveTo(const Offset(100, 300));
    await tester.pump();
    expect(width, 220);
    await gesture.moveTo(const Offset(300, 300));
    await tester.pump();
    expect(width, closeTo(300, 0.1));
    await gesture.up();
    expect(ended, 1);
  });
}
