import 'package:chess_auto_prep/design_system/components/list_search_field.dart';
import 'package:chess_auto_prep/design_system/theme/app_motion.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/design_system/theme/workspace_theme.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_creation.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_creation_screen.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../widgetbook/repertoire_cases.dart';

double contrast(Color foreground, Color background) {
  final a = Color.alphaBlend(foreground, background).computeLuminance();
  final b = background.computeLuminance();
  return (a > b ? a + .05 : b + .05) / (a > b ? b + .05 : a + .05);
}

Widget host(Widget child, ThemeData theme, {double scale = 1}) => MaterialApp(
  theme: theme,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);

void main() {
  test(
    'production themes register interpolated workspace surfaces with readable ink',
    () {
      for (final theme in [AppTheme.dark(), AppTheme.light()]) {
        final surfaces = theme.extension<WorkspaceTheme>()!;
        for (final background in [
          surfaces.canvas,
          surfaces.panel,
          surfaces.inset,
          theme.colorScheme.surfaceContainer,
        ]) {
          for (final foreground in [
            theme.colorScheme.onSurface,
            theme.colorScheme.onSurfaceVariant,
            theme.colorScheme.error,
          ]) {
            expect(
              contrast(foreground, background),
              greaterThanOrEqualTo(4.5),
              reason: '${theme.brightness}: $foreground on $background',
            );
          }
        }
        expect(
          contrast(
            theme.colorScheme.onSurface,
            theme.colorScheme.surfaceContainerHighest,
          ),
          greaterThanOrEqualTo(4.5),
        );
      }
      final dark = AppTheme.dark().extension<WorkspaceTheme>()!;
      final light = AppTheme.light().extension<WorkspaceTheme>()!;
      final midpoint = ThemeData.lerp(
        AppTheme.dark(),
        AppTheme.light(),
        .5,
      ).extension<WorkspaceTheme>()!;
      expect(midpoint.panel, Color.lerp(dark.panel, light.panel, .5));
      expect(dark.copyWith(panel: light.panel).canvas, dark.canvas);
      expect(dark.copyWith(panel: light.panel).panel, light.panel);
    },
  );

  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.dark
        ? AppTheme.dark()
        : AppTheme.light();
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
        'catalog ${brightness.name} at ${scale}x preserves readable search and keyboard rename',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(900, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            host(
              const CatalogFixture(scenario: CatalogScenario.populated),
              theme,
              scale: scale,
            ),
          );
          await tester.pumpAndSettle();
          final search = find.byType(ListSearchField);
          final input = tester.widget<TextField>(
            find.descendant(of: search, matching: find.byType(TextField)),
          );
          expect(
            contrast(input.style!.color!, theme.scaffoldBackgroundColor),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(
              input.decoration!.hintStyle!.color!,
              theme.scaffoldBackgroundColor,
            ),
            greaterThanOrEqualTo(4.5),
          );
          await tester.enterText(find.byType(TextField), 'Sicilian');
          await tester.pumpAndSettle();
          expect(find.byTooltip('Rename repertoire'), findsOneWidget);
          await tester.tap(find.byTooltip('Rename repertoire'));
          await tester.pumpAndSettle();
          final dialogField = find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          );
          expect(Theme.of(tester.element(dialogField)).brightness, brightness);
          await tester.enterText(dialogField, 'Keyboard rename');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Clear search'));
          await tester.pumpAndSettle();
          expect(find.text('Keyboard rename'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'switching themes keeps the creation draft, focus and selection',
    (tester) async {
      final light = ValueNotifier(false);
      addTearDown(light.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<bool>(
          valueListenable: light,
          builder: (_, useLight, _) => host(
            RepertoireCreationScreen(
              create: (request) async => RepertoireCreationResult(
                directoryPath: '/fixture',
                chapterPath: '/fixture/Main.pgn',
                gameCount: 0,
              ),
            ),
            useLight ? AppTheme.light() : AppTheme.dark(),
          ),
        ),
      );
      final field = find.byKey(const ValueKey('repertoire-create-name'));
      await tester.enterText(field, 'Retained draft');
      final controller = tester.widget<TextFormField>(field).controller!;
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 6,
      );
      final focus = FocusManager.instance.primaryFocus;
      light.value = true;
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(field)).brightness, Brightness.light);
      expect(tester.widget<TextFormField>(field).controller, same(controller));
      expect(controller.text, 'Retained draft');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 6),
      );
      expect(FocusManager.instance.primaryFocus, same(focus));
    },
  );

  testWidgets('reduced motion exposes the destination without a fade', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            key: const ValueKey('transition-under-test'),
            builder: (context) =>
                const QuickFadePageTransitionsBuilder().buildTransitions<void>(
                  MaterialPageRoute(builder: (_) => const SizedBox()),
                  context,
                  const AlwaysStoppedAnimation(0),
                  const AlwaysStoppedAnimation(0),
                  const Text('Destination'),
                ),
          ),
        ),
      ),
    );
    expect(find.text('Destination'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('transition-under-test')),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
  });
}
