// A chip that grew a tick when pressed would push the ones after it along
// the line: pressed or not, it is the same width.
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/ui/toggle_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pressing a chip does not change its width', (tester) async {
    Future<double> width({required bool selected}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(
            body: Center(
              child: ToggleChip(
                label: 'Blitz',
                selected: selected,
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(ToggleChip)).width;
    }

    expect(await width(selected: true), await width(selected: false));
  });
}
