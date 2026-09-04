import 'package:chess_auto_prep/features/audit/models/audit_result.dart';
import 'package:chess_auto_prep/features/tricks/services/trick_hunt_config.dart';
import 'package:chess_auto_prep/features/tricks/services/trick_hunt_persistence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toMap/fromMap round-trips every field', () {
    const config = TrickHuntConfig(
      maxPly: 24,
      minReachProb: 0.02,
      maxDiscoveryNodes: 120,
      discoveryDepth: 16,
      discoveryMultiPv: 6,
      candidateWindowCp: 90,
      maxCandidatesPerNode: 2,
      probeBudget: 10,
      probePly: 6,
      probeEvalDepth: 10,
      probeTimeoutSeconds: 30,
      maiaElo: 1600,
      useLichessInProbes: false,
      minNetGainCp: 80,
    );

    final restored = TrickHuntConfig.fromMap(config.toMap());
    expect(restored.toMap(), config.toMap());
  });

  test('fromMap falls back to defaults on missing keys', () {
    final config = TrickHuntConfig.fromMap(const {});
    const defaults = TrickHuntConfig();
    expect(config.toMap(), defaults.toMap());
    expect(config.maxPly, 30);
    expect(config.minReachProb, closeTo(0.005, 1e-9));
    expect(config.maxDiscoveryNodes, 200);
    expect(config.candidateWindowCp, 60);
    expect(config.maxCandidatesPerNode, 3);
    expect(config.probeBudget, 24);
    expect(config.probePly, 4);
    expect(config.probeTimeoutSeconds, 60);
    expect(config.useLichessInProbes, isTrue);
    expect(config.minNetGainCp, 40);
  });

  test('copyWith changes only the requested fields', () {
    const config = TrickHuntConfig();
    final changed = config.copyWith(maiaElo: 1200, probeBudget: 8);
    expect(changed.maiaElo, 1200);
    expect(changed.probeBudget, 8);
    expect(changed.discoveryDepth, config.discoveryDepth);
    expect(changed.candidateWindowCp, config.candidateWindowCp);
    expect(changed.useLichessInProbes, config.useLichessInProbes);
  });

  test('summaryLabel names the key knobs', () {
    const config = TrickHuntConfig();
    expect(config.summaryLabel, contains('SF d14'));
    expect(config.summaryLabel, contains('≤60cp'));
    expect(config.summaryLabel, contains('24 probes'));
    expect(config.summaryLabel, contains('×4ply'));
    expect(config.summaryLabel, contains('net≥40cp'));
  });

  test('snapshot round-trips, preserving isComplete=false', () {
    final snapshot = TrickHuntSnapshot(
      result: AuditResult.empty,
      config: const TrickHuntConfig(probeBudget: 6),
      isComplete: false,
    );
    final restored = trickHuntStore.decode(trickHuntStore.encode(snapshot));
    expect(restored.isComplete, isFalse);
    expect(restored.config.probeBudget, 6);
    expect(restored.result.findings, isEmpty);
  });
}
