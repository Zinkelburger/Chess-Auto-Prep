import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_creation_screen.dart';

import '../../widgetbook/main.dart';

void main() {
  testWidgets(
    'Widgetbook appearance uses production failure feedback at enlarged light scale',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final route = Uri(
        path: '/',
        queryParameters: {
          'path': 'settings/appearance/write-failure',
          'theme': '{name:Light}',
          'text-scale': '{factor:2.0}',
        },
      ).toString();
      await tester.pumpWidget(RenewalWidgetbook(initialRoute: route));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not confirm'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Widgetbook retains the workspace draft and nested library filter',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const RenewalWidgetbook(
          initialRoute: '/?path=workspace/navigation/retained-library',
        ),
      );
      await tester.pumpAndSettle();
      final draft = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Workspace draft',
      );
      await tester.enterText(draft, 'Board note');
      await tester.tap(find.text('Open library'));
      await tester.pumpAndSettle();
      final search = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Search repertoires',
      );
      await tester.enterText(search, 'Sicilian');
      await tester.tap(find.text('Switch workspace'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Return to workspace'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, 'Sicilian');
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(draft).controller!.text, 'Board note');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Widgetbook copy dialog keeps localization, theme and scale and saves the restored draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final route = Uri(
        path: '/',
        queryParameters: {
          'path': 'documents/save/conflict',
          'theme': '{name:Light}',
          'text-scale': '{factor:2.0}',
        },
      ).toString();
      await tester.pumpWidget(RenewalWidgetbook(initialRoute: route));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reload and keep draft'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore retained draft'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('document-save-copy')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(Theme.of(tester.element(field)).brightness, Brightness.light);
      expect(MediaQuery.textScalerOf(tester.element(field)).scale(14), 28);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Save'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('/fixture/Copy.pgn'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('document-draft')))
            .controller!
            .text,
        contains('My draft'),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in ['conflict', 'uncertain', 'collision']) {
    testWidgets(
      'Widgetbook exposes production document save $scenario interaction',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          RenewalWidgetbook(initialRoute: '/?path=documents/save/$scenario'),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('document-save-copy')),
          findsOneWidget,
        );
        expect(find.text('Inspect current file'), findsOneWidget);
        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();
        final editor = tester.widget<TextField>(
          find.byKey(const ValueKey('document-draft')),
        );
        expect(editor.controller!.text, contains('My draft'));
        expect(editor.focusNode!.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

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
