/// [HuntReportPanel] on its own — the ranked report both hunts render into.
///
/// The hole and trick panels were copies of each other; these pin the
/// behaviour that copying was hiding, and one defect that only appears once
/// the panel is generic: the filter chips are configured by the *host*, which
/// rebuilds them every frame, so a selected chip must survive a rebuild.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/audit/widgets/hunt_report_panel.dart';

AuditFinding _finding({
  required String fen,
  required AuditFindingType type,
  double score = 1,
}) => AuditFinding(
  type: type,
  severity: AuditSeverity.warning,
  movePath: const ['e4'],
  fen: fen,
  exploitScore: score,
);

/// Filters built fresh on every call, exactly as a host's `build` does.
List<HuntFilter> _filters() => [
  HuntFilter(
    label: 'Refutations',
    matches: (f) => f.type == AuditFindingType.refutation,
    dismissAllLabel: 'refutations',
  ),
  HuntFilter(
    label: 'Traps',
    matches: (f) => f.type == AuditFindingType.practicalTrap,
    dismissAllLabel: 'practical traps',
  ),
];

const _emptyState = HuntEmptyState(
  icon: Icons.gps_fixed,
  title: 'No report yet',
  body: 'Run a hunt to see findings here.',
  actionLabel: 'Find things',
);

Widget _panel({
  List<AuditFinding> findings = const [],
  bool isHunting = false,
  String? progressMessage,
  String? skippedPassTooltip,
  VoidCallback? onStartHunt,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 400,
      height: 600,
      child: HuntReportPanel(
        noun: 'holes',
        filters: _filters(),
        gainCpOf: (f) => 120,
        emptyState: _emptyState,
        result: null,
        liveFindings: findings,
        isHunting: isHunting,
        progressMessage: progressMessage,
        skippedPassTooltip: skippedPassTooltip,
        onStartHunt: onStartHunt,
      ),
    ),
  ),
);

void main() {
  final refutation = _finding(
    fen: 'fen-r',
    type: AuditFindingType.refutation,
    score: 3,
  );
  final trap = _finding(
    fen: 'fen-t',
    type: AuditFindingType.practicalTrap,
    score: 2,
  );

  group('empty state', () {
    testWidgets('is shown when nothing has been found and nothing is running', (
      tester,
    ) async {
      await tester.pumpWidget(_panel(onStartHunt: () {}));
      expect(find.text('No report yet'), findsOneWidget);
      expect(find.text('Find things'), findsOneWidget);
    });

    testWidgets('offers no action when the host cannot start a hunt', (
      tester,
    ) async {
      await tester.pumpWidget(_panel());
      expect(find.text('No report yet'), findsOneWidget);
      expect(find.text('Find things'), findsNothing);
    });

    testWidgets('gives way to the list as soon as a hunt is running', (
      tester,
    ) async {
      await tester.pumpWidget(_panel(isHunting: true));
      expect(find.text('No report yet'), findsNothing);
      expect(find.text('Hunting for holes...'), findsOneWidget);
    });
  });

  group('filter chips', () {
    testWidgets('count the findings they match', (tester) async {
      await tester.pumpWidget(_panel(findings: [refutation, trap]));
      await tester.pumpAndSettle();
      expect(find.text('Refutations (1)'), findsOneWidget);
      expect(find.text('Traps (1)'), findsOneWidget);
    });

    testWidgets('a selected chip survives a host rebuild', (tester) async {
      // The regression this guards: holding the HuntFilter objects in the
      // selection set meant the next rebuild handed the panel fresh
      // instances, the identity lookup missed, and the filter silently
      // switched itself off while the chip still looked pressed.
      await tester.pumpWidget(_panel(findings: [refutation, trap]));
      await tester.pumpAndSettle();
      expect(find.text('2 findings'), findsOneWidget);

      await tester.tap(find.text('Refutations (1)'));
      await tester.pumpAndSettle();
      expect(find.text('1 findings'), findsOneWidget);

      // Rebuild with an identical configuration — new HuntFilter objects.
      await tester.pumpWidget(_panel(findings: [refutation, trap]));
      await tester.pumpAndSettle();
      expect(
        find.text('1 findings'),
        findsOneWidget,
        reason: 'the Refutations filter must still be applied',
      );

      await tester.tap(find.text('Refutations (1)'));
      await tester.pumpAndSettle();
      expect(find.text('2 findings'), findsOneWidget);
    });
  });

  group('status row', () {
    testWidgets('shows the progress line instead of Re-run while hunting', (
      tester,
    ) async {
      await tester.pumpWidget(
        _panel(
          findings: [refutation],
          isHunting: true,
          progressMessage: 'Walking 12 of 40',
          onStartHunt: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Walking 12 of 40'), findsOneWidget);
      expect(find.text('Re-run'), findsNothing);
    });

    testWidgets('offers Re-run once the hunt is done', (tester) async {
      await tester.pumpWidget(
        _panel(findings: [refutation], onStartHunt: () {}),
      );
      await tester.pumpAndSettle();
      expect(find.text('Re-run'), findsOneWidget);
    });

    testWidgets('explains a skipped pass, and stays quiet when none was', (
      tester,
    ) async {
      const message = 'Trap search skipped — Maia unavailable';
      await tester.pumpWidget(_panel(findings: [refutation]));
      await tester.pumpAndSettle();
      expect(find.byTooltip(message), findsNothing);

      await tester.pumpWidget(
        _panel(findings: [refutation], skippedPassTooltip: message),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip(message), findsOneWidget);
    });
  });
}
