import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../widgetbook/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'desktop Widgetbook uses production rename, delete and recovery controls',
    (tester) async {
      final route = Uri(
        path: '/',
        queryParameters: {
          'path': 'repertoires/library/populated',
          'theme': '{name:Light}',
          'text-scale': '{factor:1.5}',
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
      expect(MediaQuery.textScalerOf(tester.element(field)).scale(14), 21);
      await tester.enterText(field, 'Desktop catalog fixture');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();
      expect(find.text('Desktop catalog fixture'), findsOneWidget);
      final row = find.ancestor(
        of: find.text('Desktop catalog fixture'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Delete repertoire')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Desktop catalog fixture'), findsNothing);
      await tester.tap(find.text('Recovery'));
      await tester.pumpAndSettle();
      expect(find.text('Desktop catalog fixture'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();
      expect(find.text('Recovery is empty'), findsOneWidget);
      await tester.tap(find.text('Back to library'));
      await tester.pumpAndSettle();
      expect(find.text('Desktop catalog fixture'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
