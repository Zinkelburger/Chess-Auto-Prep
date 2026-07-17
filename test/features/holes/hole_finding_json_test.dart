import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
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

  test('practicalTrap round-trips with gap fields', () {
    final finding = AuditFinding(
      type: AuditFindingType.practicalTrap,
      severity: AuditSeverity.warning,
      movePath: const ['d4', 'd5', 'c4'],
      fen: someFen,
      expectedEvalCp: 95,
      practicalGapCp: 80,
      exploitLine: const ['e4', 'dxe4', 'Ne5'],
      cumulativeProbability: 0.6,
      exploitScore: 0.6 * 80,
    );
    final restored = AuditFinding.fromJson(finding.toJson());
    expect(restored.type, AuditFindingType.practicalTrap);
    expect(restored.expectedEvalCp, 95);
    expect(restored.practicalGapCp, 80);
    expect(restored.exploitLine, ['e4', 'dxe4', 'Ne5']);
    expect(restored.summary, contains('Trap zone'));
    expect(restored.summary, contains('+80cp'));
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
    expect(restored.exploitScore, isNull);
  });

  test('dismissKey is unique across the three hole types at one FEN', () {
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
    final trap = AuditFinding(
      type: AuditFindingType.practicalTrap,
      severity: AuditSeverity.info,
      movePath: const [],
      fen: someFen,
    );
    final keys = {uncovered.dismissKey, refutation.dismissKey, trap.dismissKey};
    expect(keys.length, 3);
  });
}
