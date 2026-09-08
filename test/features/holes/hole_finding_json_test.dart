import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/audit/models/audit_result.dart';
import 'package:flutter_test/flutter_test.dart';

const someFen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

void main() {
  test('uncoveredStrongMove round-trips', () {
    final finding = AuditFinding(
      type: AuditFindingType.uncoveredStrongMove,
      severity: AuditSeverity.critical,
      movePath: const ['e4', 'c5'],
      fen: someFen,
      missingMove: 'Nf6',
      positionEvalCp: 35,
      bestMoveEvalCp: 40,
      cumulativeProbability: 0.42,
      exploitScore: 0.42 * 85,
      transposesIntoRepertoire: true,
    );
    final restored = AuditFinding.fromJson(finding.toJson());
    expect(restored.type, AuditFindingType.uncoveredStrongMove);
    expect(restored.missingMove, 'Nf6');
    expect(restored.exploitScore, closeTo(0.42 * 85, 1e-9));
    expect(restored.transposesIntoRepertoire, isTrue);
    expect(restored.summary, contains('Uncovered'));
    expect(restored.summary, contains('transposes'));
  });

  test('refutation round-trips with exploit line', () {
    final finding = AuditFinding(
      type: AuditFindingType.refutation,
      severity: AuditSeverity.critical,
      movePath: const ['e4', 'e5', 'Nf3'],
      fen: someFen,
      ourMove: 'Nf3',
      bestMove: 'Nc3',
      evalLossCp: 130,
      exploitLine: const ['Nxe4', 'Qe2', 'd5'],
      cumulativeProbability: 0.2,
      exploitScore: 0.2 * 130,
    );
    final restored = AuditFinding.fromJson(finding.toJson());
    expect(restored.type, AuditFindingType.refutation);
    expect(restored.exploitLine, ['Nxe4', 'Qe2', 'd5']);
    expect(restored.evalLossCp, 130);
    expect(restored.summary, contains('Refuted'));
    expect(restored.summary, contains('Nxe4 Qe2 d5'));
  });

  test('trickyMove round-trips with all trick fields', () {
    final finding = AuditFinding(
      type: AuditFindingType.trickyMove,
      severity: AuditSeverity.warning,
      movePath: const ['e4', 'c5'],
      fen: someFen,
      ourMove: 'b4',
      missingMove: 'b4',
      bestMove: 'Nf3',
      evalLossCp: 35,
      positionEvalCp: -10,
      bestMoveEvalCp: 25,
      expectedEvalCp: 90,
      practicalGapCp: 100,
      netGainCp: 65,
      oppEase: 0.22,
      isNovelty: true,
      exploitLine: const ['b4', 'cxb4', 'a3'],
      cumulativeProbability: 0.31,
      exploitScore: 0.31 * 65,
      transposesIntoRepertoire: false,
    );
    final restored = AuditFinding.fromJson(finding.toJson());
    expect(restored.type, AuditFindingType.trickyMove);
    expect(restored.ourMove, 'b4');
    expect(restored.missingMove, 'b4');
    expect(restored.bestMove, 'Nf3');
    expect(restored.evalLossCp, 35);
    expect(restored.expectedEvalCp, 90);
    expect(restored.practicalGapCp, 100);
    expect(restored.netGainCp, 65);
    expect(restored.oppEase, closeTo(0.22, 1e-9));
    expect(restored.isNovelty, isTrue);
    expect(restored.exploitLine, ['b4', 'cxb4', 'a3']);
    expect(restored.exploitScore, closeTo(0.31 * 65, 1e-9));
  });

  test('trick summary names the move, net gain, and novelty tag', () {
    final novelty = AuditFinding(
      type: AuditFindingType.trickyMove,
      severity: AuditSeverity.warning,
      movePath: const ['e4', 'c5'],
      fen: someFen,
      ourMove: 'b4',
      netGainCp: 65,
      isNovelty: true,
    );
    // Candidate is played FROM the finding's fen, i.e. at ply
    // movePath.length (White's move 2 here).
    expect(novelty.summary, contains('2. b4'));
    expect(novelty.summary, contains('+65cp'));
    expect(novelty.summary, contains('novelty'));

    final inTree = AuditFinding(
      type: AuditFindingType.trickyMove,
      severity: AuditSeverity.warning,
      movePath: const ['e4', 'c5'],
      fen: someFen,
      ourMove: 'Nf3',
      netGainCp: 40,
      isNovelty: false,
    );
    expect(inTree.summary, isNot(contains('novelty')));
  });

  test('new fields absent stay null and legacy findings still parse', () {
    final legacy = AuditFinding(
      type: AuditFindingType.mistake,
      severity: AuditSeverity.critical,
      movePath: const ['e4'],
      fen: someFen,
      ourMove: 'e4',
      bestMove: 'd4',
      evalLossCp: 110,
    );
    final restored = AuditFinding.fromJson(legacy.toJson());
    expect(restored.exploitLine, isNull);
    expect(restored.expectedEvalCp, isNull);
    expect(restored.practicalGapCp, isNull);
    expect(restored.netGainCp, isNull);
    expect(restored.oppEase, isNull);
    expect(restored.isNovelty, isNull);
    expect(restored.exploitScore, isNull);
  });

  test('a report holding a retired finding type drops just that row', () {
    // The trap pass used to write `practicalTrap` findings. A saved report
    // with one must still open, minus the row this build cannot name.
    final kept = AuditFinding(
      type: AuditFindingType.refutation,
      severity: AuditSeverity.critical,
      movePath: const ['e4'],
      fen: someFen,
      ourMove: 'e4',
    );
    final json = AuditResult(
      findings: [kept],
      nodesChecked: 1,
      ourMoveNodesChecked: 1,
      opponentNodesChecked: 0,
      leafNodesChecked: 0,
      elapsed: Duration.zero,
    ).toJson();
    (json['findings'] as List).add({
      'type': 'practicalTrap',
      'severity': 'warning',
      'movePath': ['d4'],
      'fen': someFen,
    });
    final restored = AuditResult.fromJson(json);
    expect(restored.findings.map((f) => f.type), [AuditFindingType.refutation]);
  });

  test('dismissKey is unique across the hole types at one FEN', () {
    final uncovered = AuditFinding(
      type: AuditFindingType.uncoveredStrongMove,
      severity: AuditSeverity.info,
      movePath: const [],
      fen: someFen,
      missingMove: 'Nf6',
    );
    final refutation = AuditFinding(
      type: AuditFindingType.refutation,
      severity: AuditSeverity.info,
      movePath: const [],
      fen: someFen,
      ourMove: 'Nf3',
    );
    AuditFinding trick(String san) => AuditFinding(
      type: AuditFindingType.trickyMove,
      severity: AuditSeverity.info,
      movePath: const [],
      fen: someFen,
      ourMove: san,
    );
    final keys = {
      uncovered.dismissKey,
      refutation.dismissKey,
      trick('b4').dismissKey,
      trick('Nf3').dismissKey,
    };
    expect(keys.length, 4);
  });
}
