import 'package:chess_auto_prep/features/holes/services/hole_hunt_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toMap/fromMap round-trips every field', () {
    const config = HoleHuntConfig(
      attackerIsUser: false,
      discoveryDepth: 16,
      discoveryMultiPv: 6,
      maxPly: 24,
      strongMoveWindowCp: 40,
      uncoveredMinAdvantageCp: -50,
      outOfBookBonusCp: 30,
      refutationThresholdCp: 120,
      verifyDepth: 22,
      trapLeafCount: 8,
      trapSearchPly: 5,
      trapEvalDepth: 10,
      practicalGapThresholdCp: 80,
      maiaElo: 1600,
      useLichessInTraps: false,
      maxReportSize: 15,
    );

    final restored = HoleHuntConfig.fromMap(config.toMap());
    expect(restored.toMap(), config.toMap());
  });

  test('fromMap falls back to defaults on missing keys', () {
    final config = HoleHuntConfig.fromMap(const {});
    const defaults = HoleHuntConfig();
    expect(config.toMap(), defaults.toMap());
    expect(config.attackerIsUser, isTrue);
    expect(config.discoveryDepth, 14);
    expect(config.refutationThresholdCp, 80);
    expect(config.trapLeafCount, 12);
    expect(config.practicalGapThresholdCp, 60);
    expect(config.maxReportSize, 10);
  });

  test('copyWith changes only the requested fields', () {
    const config = HoleHuntConfig();
    final changed = config.copyWith(maiaElo: 1200, trapLeafCount: 4);
    expect(changed.maiaElo, 1200);
    expect(changed.trapLeafCount, 4);
    expect(changed.discoveryDepth, config.discoveryDepth);
    expect(changed.attackerIsUser, config.attackerIsUser);
  });

  test('summaryLabel names the key knobs', () {
    const config = HoleHuntConfig();
    expect(config.summaryLabel, contains('SF d14'));
    expect(config.summaryLabel, contains('30ply'));
    expect(config.summaryLabel, contains('refute≥80cp'));
    expect(config.summaryLabel, contains('12 leaves'));
    expect(config.summaryLabel, contains('gap≥60cp'));
  });
}
