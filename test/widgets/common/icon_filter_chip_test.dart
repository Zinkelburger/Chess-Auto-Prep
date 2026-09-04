/// [IconFilterChip] — the view-picker chip the three layout zones share.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/widgets/common/icon_filter_chip.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

Color _iconColor(WidgetTester tester) =>
    tester.widget<Icon>(find.byType(Icon)).color!;

void main() {
  testWidgets('shows its label and icon', (tester) async {
    await tester.pumpWidget(
      _host(
        IconFilterChip(
          label: 'Eval Tree',
          icon: Icons.insights,
          selected: false,
          onSelected: (_) {},
        ),
      ),
    );
    expect(find.text('Eval Tree'), findsOneWidget);
    expect(find.byIcon(Icons.insights), findsOneWidget);
  });

  testWidgets('the icon goes accent when selected, muted when not', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        IconFilterChip(
          label: 'Traps',
          icon: Icons.warning_amber_rounded,
          selected: false,
          onSelected: (_) {},
        ),
      ),
    );
    expect(_iconColor(tester), AppColors.onSurfaceMuted);

    await tester.pumpWidget(
      _host(
        IconFilterChip(
          label: 'Traps',
          icon: Icons.warning_amber_rounded,
          selected: true,
          onSelected: (_) {},
        ),
      ),
    );
    expect(_iconColor(tester), AppColors.accent);
  });

  testWidgets('reports the new selection when tapped', (tester) async {
    bool? got;
    await tester.pumpWidget(
      _host(
        IconFilterChip(
          label: 'Metrics',
          icon: Icons.bar_chart,
          selected: false,
          onSelected: (v) => got = v,
        ),
      ),
    );
    await tester.tap(find.text('Metrics'));
    await tester.pumpAndSettle();
    expect(got, isTrue);
  });

  testWidgets('a null callback disables it, which is how tabs lock', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const IconFilterChip(
          label: 'Tree',
          icon: Icons.account_tree,
          selected: true,
          onSelected: null,
        ),
      ),
    );
    expect(
      tester.widget<FilterChip>(find.byType(FilterChip)).isEnabled,
      isFalse,
    );
  });
}
