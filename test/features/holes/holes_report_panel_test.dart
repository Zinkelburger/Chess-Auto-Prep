/// [HolesReportPanel] on its own — the ranked report the hunt renders into.
///
/// Pins the empty state, the filter chips (including that a selected chip
/// survives a host rebuild — the host rebuilds the panel every frame while
/// findings stream in), the status row, and stepping through the list from
/// a [ListNavController] exactly as clicks would.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/holes/services/hole_hunt_service.dart';
import 'package:chess_auto_prep/features/holes/widgets/holes_report_panel.dart';
import 'package:chess_auto_prep/widgets/common/list_nav.dart';

AuditFinding _finding({
  required String fen,
  AuditFindingType type = AuditFindingType.refutation,
  double score = 1,
}) => AuditFinding(
  type: type,
  severity: AuditSeverity.warning,
  movePath: const ['e4'],
  fen: fen,
  exploitScore: score,
);

Widget _panel({
  List<AuditFinding> findings = const [],
  bool isHunting = false,
  HoleHuntProgress? progress,
  bool probesSkipped = false,
  VoidCallback? onStartHunt,
  ListNavController? navController,
  void Function(AuditFinding)? onFindingSelected,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 400,
      height: 600,
      child: HolesReportPanel(
        result: null,
        liveFindings: findings,
        isHunting: isHunting,
        progress: progress,
        probesSkipped: probesSkipped,
        onStartHunt: onStartHunt,
        navController: navController,
        onFindingSelected: onFindingSelected,
      ),
    ),
  ),
);

void main() {
  final refutation = _finding(fen: 'fen-r', score: 3);
  final trick = _finding(
    fen: 'fen-t',
    type: AuditFindingType.trickyMove,
    score: 2,
  );

  group('empty state', () {
    testWidgets('is shown when nothing has been found and nothing is running', (
      tester,
    ) async {
      await tester.pumpWidget(_panel(onStartHunt: () {}));
      expect(find.text('No hole report yet'), findsOneWidget);
      expect(find.text('Find Holes'), findsOneWidget);
    });

    testWidgets('offers no action when the host cannot start a hunt', (
      tester,
    ) async {
      await tester.pumpWidget(_panel());
      expect(find.text('No hole report yet'), findsOneWidget);
      expect(find.text('Find Holes'), findsNothing);
    });

    testWidgets('gives way to the list as soon as a hunt is running', (
      tester,
    ) async {
      await tester.pumpWidget(_panel(isHunting: true));
      expect(find.text('No hole report yet'), findsNothing);
      expect(find.text('Hunting for holes...'), findsOneWidget);
    });
  });

  group('filter chips', () {
    testWidgets('count the findings they match', (tester) async {
      await tester.pumpWidget(_panel(findings: [refutation, trick]));
      await tester.pumpAndSettle();
      expect(find.text('Uncovered (0)'), findsOneWidget);
      expect(find.text('Refutations (1)'), findsOneWidget);
      expect(find.text('Tricks (1)'), findsOneWidget);
    });

    testWidgets('a selected chip survives a host rebuild', (tester) async {
      await tester.pumpWidget(_panel(findings: [refutation, trick]));
      await tester.pumpAndSettle();
      expect(find.text('2 findings'), findsOneWidget);

      await tester.tap(find.text('Refutations (1)'));
      await tester.pumpAndSettle();
      expect(find.text('1 findings'), findsOneWidget);

      // Rebuild with an identical configuration.
      await tester.pumpWidget(_panel(findings: [refutation, trick]));
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
          progress: const HoleHuntProgress(
            phase: HoleHuntPhase.walking,
            done: 12,
            total: 40,
          ),
          onStartHunt: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Walking 12 / 40 positions'), findsOneWidget);
      expect(find.text('Re-run'), findsNothing);
    });

    testWidgets('offers Re-run once the hunt is done', (tester) async {
      await tester.pumpWidget(
        _panel(findings: [refutation], onStartHunt: () {}),
      );
      await tester.pumpAndSettle();
      expect(find.text('Re-run'), findsOneWidget);
    });

    testWidgets(
      'explains a skipped trick search, and stays quiet when none was',
      (tester) async {
        const message = 'Trick search skipped — Maia unavailable';
        await tester.pumpWidget(_panel(findings: [refutation]));
        await tester.pumpAndSettle();
        expect(find.byTooltip(message), findsNothing);

        await tester.pumpWidget(
          _panel(findings: [refutation], probesSkipped: true),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip(message), findsOneWidget);
      },
    );
  });

  testWidgets('nav controller steps the report like clicks would', (
    tester,
  ) async {
    final selections = <String>[];
    final controller = ListNavController();
    // Exploit scores rank them fen-a, fen-b, fen-c.
    final findings = [
      _finding(fen: 'fen-b', score: 2),
      _finding(fen: 'fen-a', score: 3),
      _finding(fen: 'fen-c', score: 1),
    ];

    await tester.pumpWidget(
      _panel(
        findings: findings,
        navController: controller,
        onFindingSelected: (f) => selections.add(f.fen),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Prev'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);

    controller.selectNext();
    await tester.pumpAndSettle();
    expect(selections, ['fen-a']);
    expect(find.text('1 of 3'), findsOneWidget);

    controller.selectNext();
    controller.selectNext();
    controller.selectNext();
    await tester.pumpAndSettle();
    expect(selections, ['fen-a', 'fen-b', 'fen-c'], reason: 'clamps at end');
    expect(find.text('3 of 3'), findsOneWidget);

    controller.selectPrevious();
    await tester.pumpAndSettle();
    expect(selections.last, 'fen-b');
    expect(find.text('2 of 3'), findsOneWidget);
  });
}
