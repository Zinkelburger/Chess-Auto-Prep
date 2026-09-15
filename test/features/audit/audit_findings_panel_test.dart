import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/audit/models/audit_result.dart';
import 'package:chess_auto_prep/features/audit/widgets/audit_findings_panel.dart';
import 'package:chess_auto_prep/features/audit/widgets/finding_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AuditFinding finding(String move, AuditSeverity severity, double frequency) =>
    AuditFinding(
      type: AuditFindingType.missingResponse,
      severity: severity,
      movePath: const ['e4'],
      fen: 'position',
      missingMove: move,
      cumulativeProbability: frequency,
    );

AuditResult report(
  List<AuditFinding> findings, {
  List<String> warnings = const [],
}) => AuditResult(
  findings: findings,
  nodesChecked: 4,
  ourMoveNodesChecked: 2,
  opponentNodesChecked: 1,
  leafNodesChecked: 1,
  elapsed: Duration.zero,
  warnings: warnings,
);

Future<void> showPanel(WidgetTester tester, AuditFindingsPanel panel) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: panel)));
  await tester.pump();
}

void main() {
  testWidgets('a new audit has a working start action', (tester) async {
    var started = false;
    await showPanel(
      tester,
      AuditFindingsPanel(onStartAudit: () => started = true),
    );
    await tester.tap(find.text('Start audit'));
    expect(started, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'priority surfaces serious rare findings and frequency is optional',
    (tester) async {
      final common = finding('e5', AuditSeverity.info, 0.9);
      final serious = finding('c5', AuditSeverity.critical, 0.01);
      await showPanel(
        tester,
        AuditFindingsPanel(result: report([common, serious])),
      );
      expect(
        tester.widgetList<FindingTile>(find.byType(FindingTile)).first.finding,
        same(serious),
      );
      await tester.tap(find.text('Frequency'));
      await tester.pumpAndSettle();
      expect(
        tester.widgetList<FindingTile>(find.byType(FindingTile)).first.finding,
        same(common),
      );
    },
  );

  testWidgets(
    'search empty state clears filters instead of starting another run',
    (tester) async {
      await showPanel(
        tester,
        AuditFindingsPanel(
          result: report([finding('c5', AuditSeverity.critical, 1)]),
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'not-a-move');
      await tester.pump();
      expect(find.text('No findings match these filters'), findsOneWidget);
      expect(find.text('Start audit'), findsNothing);
      await tester.tap(find.text('Clear filters').first);
      await tester.pump();
      expect(find.byType(FindingTile), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets('search and source notice fit a compact findings pane', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(650, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await showPanel(
      tester,
      AuditFindingsPanel(
        chapterName: 'Open games',
        subtreeOnly: true,
        result: report(
          [finding('c5', AuditSeverity.critical, 1)],
          warnings: ['Maia unavailable'],
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'missing');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Subtree'), findsOneWidget);
  });

  testWidgets('live insertions preserve the selected finding', (tester) async {
    final selected = finding('e5', AuditSeverity.info, 0.9);
    final inserted = finding('c5', AuditSeverity.critical, 0.1);
    final key = GlobalKey<AuditFindingsPanelState>();
    await showPanel(
      tester,
      AuditFindingsPanel(key: key, liveFindings: [selected], isAuditing: true),
    );
    await tester.tap(find.byType(FindingTile));
    await tester.pump();
    await showPanel(
      tester,
      AuditFindingsPanel(
        key: key,
        liveFindings: [selected, inserted],
        isAuditing: true,
      ),
    );
    final tile = tester
        .widgetList<FindingTile>(find.byType(FindingTile))
        .singleWhere((tile) => tile.isSelected);
    expect(tile.finding, same(selected));
  });

  testWidgets('unavailable checks are visible and never imply an all-clear', (
    tester,
  ) async {
    await showPanel(
      tester,
      AuditFindingsPanel(
        result: report([], warnings: ['Maia unavailable']),
        errorText: 'Audit could not finish.',
      ),
    );
    expect(find.text('Some checks unavailable'), findsOneWidget);
    expect(find.text('No findings from the available checks'), findsOneWidget);
    expect(find.text('Audit could not finish.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'soundness counts an affected position once and warnings round trip',
    () {
      final move = AuditFinding(
        type: AuditFindingType.mistake,
        severity: AuditSeverity.critical,
        movePath: const ['e4'],
        fen: 'after e4',
      );
      final weak = AuditFinding(
        type: AuditFindingType.weakPosition,
        severity: AuditSeverity.warning,
        movePath: const ['e4'],
        fen: 'after e4',
      );
      final result = report(
        [move, weak],
        warnings: ['Some checks unavailable'],
      );
      expect(result.soundnessPercent, 50);
      expect(AuditResult.fromJson(result.toJson()).warnings, [
        'Some checks unavailable',
      ]);
    },
  );
}
