import 'package:chess_auto_prep/widgets/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a narrow preference row keeps stepper controls usable at their limits',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var value = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SettingsStepperTile(
                label: 'Analysis workers',
                description: 'Leave resources available for other apps.',
                value: value,
                min: 1,
                max: 2,
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.remove))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('More'));
      await tester.pump();
      expect(value, 2);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Less'));
      await tester.pump();
      expect(value, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
