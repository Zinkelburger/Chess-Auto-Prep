import 'package:chess_auto_prep/widgets/common/horizontal_wheel_scroll.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('wheel scrolls sideways and passes to parent at an edge', (
    tester,
  ) async {
    final horizontal = ScrollController();
    final vertical = ScrollController();
    addTearDown(horizontal.dispose);
    addTearDown(vertical.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: vertical,
            child: Column(
              children: [
                SizedBox(
                  width: 200,
                  height: 60,
                  child: HorizontalWheelScroll(
                    controller: horizontal,
                    child: const SizedBox(
                      width: 1000,
                      child: Text('Horizontal strip'),
                    ),
                  ),
                ),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        ),
      ),
    );
    final point = tester.getCenter(find.byType(HorizontalWheelScroll));
    Future<void> wheel(Offset delta) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: delta),
      );
      await tester.pump();
    }

    await wheel(const Offset(0, 120));
    expect(horizontal.offset, 120);
    expect(vertical.offset, 0);
    await wheel(const Offset(50, 0));
    expect(horizontal.offset, 170);
    await wheel(const Offset(0, -80));
    expect(horizontal.offset, 90);
    horizontal.jumpTo(horizontal.position.maxScrollExtent);
    await wheel(const Offset(0, 100));
    expect(vertical.offset, 100);
    expect(tester.takeException(), isNull);
  });
}
