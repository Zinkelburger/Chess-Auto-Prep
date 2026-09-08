import 'package:chess_auto_prep/features/audit/models/audit_result.dart';
import 'package:chess_auto_prep/features/holes/services/hole_hunt_config.dart';
import 'package:chess_auto_prep/features/holes/services/hole_hunt_persistence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toMap/fromMap round-trips every field', () {
    const config = HoleHuntConfig(
      discoveryDepth: 16,
      discoveryMultiPv: 6,
      maxPly: 24,
      strongMoveWindowCp: 40,
      uncoveredMinAdvantageCp: -50,
      outOfBookBonusCp: 30,
      refutationThresholdCp: 120,
      verifyDepth: 22,
      candidateWindowCp: 90,
      probeBudget: 10,
      probePly: 6,
      probeEvalDepth: 10,
      minNetGainCp: 80,
      maiaElo: 1600,
    );

    final restored = HoleHuntConfig.fromMap(config.toMap());
    expect(restored.toMap(), config.toMap());
  });

  test('fromMap falls back to defaults on missing keys', () {
    final config = HoleHuntConfig.fromMap(const {});
    const defaults = HoleHuntConfig();
    expect(config.toMap(), defaults.toMap());
    expect(config.discoveryDepth, 14);
    expect(config.refutationThresholdCp, 80);
    expect(config.candidateWindowCp, 60);
    expect(config.probeBudget, 24);
    expect(config.probePly, 4);
    expect(config.minNetGainCp, 40);
  });

  test('a report saved by the old two-pass hunt still reads', () {
    // Keys the trap pass and the separate trick hunt used to store are
    // simply ignored; the knobs both hunts shared keep their values.
    final config = HoleHuntConfig.fromMap(const {
      'attackerIsUser': false,
      'trapLeafCount': 8,
      'practicalGapThresholdCp': 60,
      'useLichessInTraps': true,
      'discoveryDepth': 16,
      'maiaElo': 1800,
    });
    expect(config.discoveryDepth, 16);
    expect(config.maiaElo, 1800);
    expect(config.probeBudget, 24);
  });

  test('copyWith changes only the requested fields', () {
    const config = HoleHuntConfig();
    final changed = config.copyWith(maiaElo: 1200, probeBudget: 8);
    expect(changed.maiaElo, 1200);
    expect(changed.probeBudget, 8);
    expect(changed.discoveryDepth, config.discoveryDepth);
    expect(changed.candidateWindowCp, config.candidateWindowCp);
  });

  test('summaryLabel names the key knobs', () {
    const config = HoleHuntConfig();
    expect(config.summaryLabel, contains('SF d14'));
    expect(config.summaryLabel, contains('30ply'));
    expect(config.summaryLabel, contains('refute≥80cp'));
    expect(config.summaryLabel, contains('24 probes'));
    expect(config.summaryLabel, contains('×4ply'));
    expect(config.summaryLabel, contains('net≥40cp'));
  });

  test('snapshot round-trips, preserving isComplete=false', () {
    final snapshot = HoleHuntSnapshot(
      result: AuditResult.empty,
      config: const HoleHuntConfig(probeBudget: 6),
      isComplete: false,
    );
    final restored = holeHuntStore.decode(holeHuntStore.encode(snapshot));
    expect(restored.isComplete, isFalse);
    expect(restored.config.probeBudget, 6);
    expect(restored.result.findings, isEmpty);
  });
}
