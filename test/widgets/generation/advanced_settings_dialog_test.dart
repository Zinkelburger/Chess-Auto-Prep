/// Tests for the advanced-settings dialog chrome.
///
/// This code used to live inside `_GenerationConfigAdvanced`, a mixin on the
/// 2,300-line `GenerationConfigFormState`, where reaching it meant building
/// the whole form and every knob in it. Pulled out as a widget that takes
/// its sections as an argument, it can be driven directly — which is the
/// point of the extraction, not a side effect of it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/generation/advanced_settings_dialog.dart';

/// A section whose builder records how many times it was asked to build and
/// exposes a button that calls `refresh`.
AdvancedSection _section(
  String title, {
  IconData icon = Icons.tune,
  List<String> Function()? body,
  void Function()? onBuilt,
}) => AdvancedSection(title, icon, (refresh) {
  onBuilt?.call();
  return [
    for (final label in body?.call() ?? const <String>[]) Text(label),
    TextButton(onPressed: refresh, child: Text('refresh $title')),
  ];
});

Future<void> _open(
  WidgetTester tester,
  List<AdvancedSection> sections, {
  Size size = const Size(1000, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                AdvancedSettingsDialog.show(context, sections: sections),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every section is rendered as its own titled card', (
    tester,
  ) async {
    await _open(tester, [
      _section('Opponent model', body: () => ['maia elo']),
      _section('Move choice', body: () => ['selection mode']),
    ]);

    // Each title appears twice on a wide layout: once in the table of
    // contents, once as the card heading.
    expect(find.text('Opponent model'), findsNWidgets(2));
    expect(find.text('Move choice'), findsNWidgets(2));
    expect(find.text('maia elo'), findsOneWidget);
    expect(find.text('selection mode'), findsOneWidget);
  });

  testWidgets('the table of contents is dropped on a narrow window', (
    tester,
  ) async {
    // Below 860 logical pixels the jump links would crowd out the controls,
    // so the dialog drops to a single column.
    await _open(tester, [
      _section('Opponent model'),
    ], size: const Size(700, 800));

    expect(
      find.text('SECTIONS'),
      findsNothing,
      reason: 'the TOC header should not render on a narrow layout',
    );
    expect(
      find.text('Opponent model'),
      findsOneWidget,
      reason: 'the card heading is the only remaining copy of the title',
    );
  });

  testWidgets('the table of contents appears once the window is wide', (
    tester,
  ) async {
    await _open(tester, [
      _section('Opponent model'),
    ], size: const Size(900, 800));

    expect(find.text('SECTIONS'), findsOneWidget);
  });

  testWidgets('refresh rebuilds every section, not just its own', (
    tester,
  ) async {
    // A knob in one card can enable or disable a field in another, so a
    // refresh has to rebuild the whole dialog. Anything narrower silently
    // leaves the other cards showing stale enablement.
    var otherBuilds = 0;
    await _open(tester, [
      _section('Move choice'),
      _section('PGN export', onBuilt: () => otherBuilds++),
    ]);

    final before = otherBuilds;
    await tester.tap(find.text('refresh Move choice'));
    await tester.pumpAndSettle();

    expect(otherBuilds, greaterThan(before));
  });

  testWidgets('a section builder sees state that changed since it opened', (
    tester,
  ) async {
    // The sections read live form state through closures rather than being
    // handed a snapshot, which is what lets the dialog and the main form
    // stay in sync while both are open.
    var label = 'before';
    await _open(tester, [
      _section('Move choice', body: () => [label]),
    ]);

    expect(find.text('before'), findsOneWidget);

    label = 'after';
    await tester.tap(find.text('refresh Move choice'));
    await tester.pumpAndSettle();

    expect(find.text('after'), findsOneWidget);
    expect(find.text('before'), findsNothing);
  });

  testWidgets('each section keeps its own scroll anchor', (tester) async {
    // The anchor lives on the section rather than the dialog so a jump link
    // and its card cannot disagree about which one it points at.
    final a = _section('Opponent model');
    final b = _section('PGN export');

    expect(a.anchor, isNot(same(b.anchor)));

    await _open(tester, [a, b]);

    expect(a.anchor.currentContext, isNotNull);
    expect(b.anchor.currentContext, isNotNull);
  });

  testWidgets('cards stay mounted so an off-screen anchor is reachable', (
    tester,
  ) async {
    // Deliberately not a ListView: the TOC's Scrollable.ensureVisible needs
    // every anchor to have a context, including sections scrolled far out of
    // view. A lazy list would leave the last card unbuilt and its jump link
    // dead.
    final sections = [
      for (var i = 0; i < 12; i++)
        _section('Section $i', body: () => ['field $i']),
    ];

    await _open(tester, sections, size: const Size(1000, 400));

    expect(sections.last.anchor.currentContext, isNotNull);
  });

  testWidgets('tapping a jump link scrolls its card into view', (tester) async {
    final sections = [
      for (var i = 0; i < 12; i++)
        _section('Section $i', body: () => ['field $i']),
    ];
    await _open(tester, sections, size: const Size(1000, 400));

    // The TOC entry is the copy inside the ListView; the card heading is the
    // other. Tapping the first one is what a user does.
    await tester.tap(find.text('Section 11').first);
    await tester.pumpAndSettle();

    expect(find.text('field 11'), findsOneWidget);
  });

  testWidgets('the close button dismisses the dialog', (tester) async {
    await _open(tester, [_section('Move choice')]);

    expect(find.byType(AdvancedSettingsDialog), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.byType(AdvancedSettingsDialog), findsNothing);
  });

  testWidgets('show() completes only once the dialog is dismissed', (
    tester,
  ) async {
    // The form repaints its summary after this future completes, so a future
    // that resolves early would leave the main form showing stale values.
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await AdvancedSettingsDialog.show(
                  context,
                  sections: [_section('Move choice')],
                );
                done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(done, isFalse);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(done, isTrue);
  });

  testWidgets('an empty section list still renders the dialog', (tester) async {
    await _open(tester, const []);

    expect(find.byType(AdvancedSettingsDialog), findsOneWidget);
    expect(find.text('Advanced generation settings'), findsOneWidget);
  });
}
