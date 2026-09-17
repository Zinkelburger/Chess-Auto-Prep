import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_creation_screen.dart';

import '../../widgetbook/main.dart';

void main() {
  testWidgets(
    'Widgetbook runs production creation with scripted failure and retained draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const RenewalWidgetbook(
          initialRoute: '/?path=repertoires/creation/failure',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
      await tester.pumpAndSettle();
      expect(find.byType(RepertoireCreationScreen), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('repertoire-create-name')),
        'Widgetbook draft',
      );
      await tester.tap(find.text('Empty repertoire'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Import preparation failed. No repertoire was published. Keep this draft and retry.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('repertoire-create-name')),
            )
            .controller!
            .text,
        'Widgetbook draft',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Widgetbook dialogs inherit the selected light theme and 200 percent scale',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final route = Uri(
        path: '/',
        queryParameters: {
          'path': 'repertoires/library/populated',
          'theme': '{name:Light}',
          'text-scale': '{factor:2.0}',
        },
      ).toString();
      await tester.pumpWidget(RenewalWidgetbook(initialRoute: route));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Rename repertoire').first);
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(Theme.of(tester.element(field)).brightness, Brightness.light);
      expect(MediaQuery.textScalerOf(tester.element(field)).scale(14), 28);
      expect(tester.takeException(), isNull);
    },
  );
}
