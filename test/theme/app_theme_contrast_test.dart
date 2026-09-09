import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/theme/app_theme.dart';
import 'package:chess_auto_prep/widgets/app_overflow_menu.dart';
import 'package:chess_auto_prep/widgets/engine/inline_engine_settings.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color foreground, Color background) {
  final a = Color.alphaBlend(foreground, background).computeLuminance();
  final b = background.computeLuminance();
  return (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
}

Material panelFor(WidgetTester tester, Finder label) => tester
    .widgetList<Material>(
      find.ancestor(of: label, matching: find.byType(Material)),
    )
    .firstWhere((material) => material.color != null && material.color!.a == 1);

void expectRaised(Material panel) {
  expect(
    panel.color!.computeLuminance(),
    greaterThan(AppColors.surface.computeLuminance()),
  );
  final shape = panel.shape! as OutlinedBorder;
  expect(shape.side.style, BorderStyle.solid);
  expect(
    contrast(shape.side.color, AppColors.surface),
    greaterThanOrEqualTo(3),
  );
}

void expectTextContrast(WidgetTester tester, String label, Color background) {
  final rich = tester.widget<RichText>(
    find
        .descendant(of: find.text(label), matching: find.byType(RichText))
        .first,
  );
  expect(
    contrast(rich.text.style!.color!, background),
    greaterThanOrEqualTo(4.5),
    reason: label,
  );
}

void main() {
  testWidgets(
    'Actions and Export submenus stay raised and readable on hover and focus',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AppOverflowMenu(
                  openOnHover: true,
                  entries: [
                    AppMenuEntry(
                      label: 'Export',
                      icon: Icons.download,
                      onRun: () {},
                      children: [
                        AppMenuEntry(
                          label: 'Save PGN',
                          icon: Icons.save,
                          onRun: () {},
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 100));
      await mouse.moveTo(tester.getCenter(find.text('Actions')));
      await tester.pumpAndSettle();
      final panel = panelFor(tester, find.text('Export'));
      expectRaised(panel);
      expectTextContrast(tester, 'Export', panel.color!);
      await mouse.moveTo(tester.getCenter(find.text('Export')));
      await tester.pumpAndSettle();
      final submenu = panelFor(tester, find.text('Save PGN'));
      expectRaised(submenu);
      final buttonFinder = find.byType(MenuItemButton);
      final button = tester.widget<MenuItemButton>(buttonFinder);
      final style = button.defaultStyleOf(tester.element(buttonFinder));
      for (final state in [
        WidgetState.hovered,
        WidgetState.focused,
        WidgetState.pressed,
      ]) {
        final states = {state};
        final background = Color.alphaBlend(
          style.overlayColor!.resolve(states)!,
          submenu.color!,
        );
        expectTextContrast(tester, 'Save PGN', background);
        expect(
          contrast(style.iconColor!.resolve(states)!, background),
          greaterThanOrEqualTo(3),
        );
      }
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'engine settings labels, inputs and helper text contrast with their raised panel',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: InlineEngineSettings()),
        ),
      );
      await tester.tap(find.byTooltip('Engine settings'));
      await tester.pumpAndSettle();
      final panel = panelFor(tester, find.text('Cores'));
      expectRaised(panel);
      for (final label in [
        'Engine settings',
        'Cores',
        'Lines',
        'Depth',
        'Memory (MB)',
        'Shared with global engine settings.',
      ]) {
        expectTextContrast(tester, label, panel.color!);
      }
      for (final input in tester.widgetList<EditableText>(
        find.byType(EditableText),
      )) {
        expect(
          contrast(input.style.color!, panel.color!),
          greaterThanOrEqualTo(4.5),
        );
      }
    },
  );

  testWidgets('legacy popup menus share the raised surface', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: PopupMenuButton<int>(
            itemBuilder: (_) => [
              const PopupMenuItem(value: 1, child: Text('Open file')),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
    final panel = panelFor(tester, find.text('Open file'));
    expectRaised(panel);
    expectTextContrast(tester, 'Open file', panel.color!);
  });

  testWidgets(
    'hover tooltips pair explicit light text with a dark outlined surface',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: IconButton(
              tooltip: 'Engine settings',
              onPressed: () {},
              icon: const Icon(Icons.settings),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 400));
      await mouse.moveTo(tester.getCenter(find.byType(IconButton)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final decoration = tester
          .widgetList<Container>(
            find.ancestor(
              of: find.text('Engine settings'),
              matching: find.byType(Container),
            ),
          )
          .map((container) => container.decoration)
          .whereType<BoxDecoration>()
          .first;
      expectTextContrast(tester, 'Engine settings', decoration.color!);
      expect(decoration.border, isNotNull);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
