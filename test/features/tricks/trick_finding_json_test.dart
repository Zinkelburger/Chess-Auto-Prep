import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:flutter_test/flutter_test.dart';

const someFen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

void main() {
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

  test('summary names the move, net gain, and novelty tag', () {
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

  test('dismissKey is unique per (position, candidate)', () {
    AuditFinding trick(String san) => AuditFinding(
      type: AuditFindingType.trickyMove,
      severity: AuditSeverity.info,
      movePath: const [],
      fen: someFen,
      ourMove: san,
    );
    final keys = {trick('b4').dismissKey, trick('Nf3').dismissKey};
    expect(keys.length, 2);
  });

  test('trick fields stay null on findings that never set them', () {
    final legacy = AuditFinding(
      type: AuditFindingType.refutation,
      severity: AuditSeverity.critical,
      movePath: const ['e4'],
      fen: someFen,
      ourMove: 'e4',
      evalLossCp: 120,
    );
    final restored = AuditFinding.fromJson(legacy.toJson());
    expect(restored.netGainCp, isNull);
    expect(restored.oppEase, isNull);
    expect(restored.isNovelty, isNull);
  });
}
