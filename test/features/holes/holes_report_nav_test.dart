import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/holes/widgets/holes_report_panel.dart';
import 'package:chess_auto_prep/widgets/common/list_nav.dart';

AuditFinding _finding(String fen, double score) => AuditFinding(
  type: AuditFindingType.refutation,
  severity: AuditSeverity.warning,
  movePath: const ['e4'],
  fen: fen,
  exploitScore: score,
);

void main() {
  testWidgets('nav controller steps the holes report like clicks would', (
    tester,
  ) async {
    final selections = <String>[];
    final controller = ListNavController();
    // Exploit scores rank them fen-a, fen-b, fen-c.
    final findings = [
      _finding('fen-b', 2),
      _finding('fen-a', 3),
      _finding('fen-c', 1),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: HolesReportPanel(
              result: null,
              liveFindings: findings,
              isHunting: false,
              navController: controller,
              onFindingSelected: (f) => selections.add(f.fen),
            ),
          ),
        ),
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
