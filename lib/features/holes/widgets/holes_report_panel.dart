/// Ranked hole-hunt report for the Findings tab.
///
/// The list, the cap, the dismissal and the stepping are [HuntReportPanel],
/// shared with the trick hunt. What is here is what makes it the *hole*
/// report: findings split by type, and a gain recovered from the stored
/// exploit score.
library;

import 'package:flutter/material.dart';

import '../../../widgets/common/list_nav.dart';
import '../../audit/models/audit_finding.dart';
import '../../audit/models/audit_result.dart';
import '../../audit/widgets/hunt_report_panel.dart';
import '../services/hole_hunt_service.dart';

/// Gain (cp) recovered from the stored exploit score — the same value
/// `hole_scoring.exploitScoreOf` multiplied by the reach probability.
///
/// Falls back to the raw per-type number for a finding written before
/// exploit scores were stored.
int? holeGainCp(AuditFinding f) {
  final score = f.exploitScore;
  final p = f.cumulativeProbability;
  if (score != null && p != null && p > 0) return (score / p).round();
  return switch (f.type) {
    AuditFindingType.refutation => f.evalLossCp,
    AuditFindingType.practicalTrap => f.practicalGapCp,
    _ => null,
  };
}

HuntFilter _byType(String label, AuditFindingType type, String plural) =>
    HuntFilter(
      label: label,
      matches: (f) => f.type == type,
      dismissAllLabel: plural,
    );

class HolesReportPanel extends StatelessWidget {
  const HolesReportPanel({
    super.key,
    required this.result,
    required this.liveFindings,
    required this.isHunting,
    this.progress,
    this.trapPassSkipped = false,
    this.onFindingSelected,
    this.onResultChanged,
    this.onStartHunt,
    this.navController,
  });

  final AuditResult? result;
  final List<AuditFinding> liveFindings;
  final bool isHunting;
  final HoleHuntProgress? progress;

  /// Show the "trap search skipped" note (Maia unavailable).
  final bool trapPassSkipped;

  final void Function(AuditFinding finding)? onFindingSelected;
  final void Function(AuditResult result)? onResultChanged;

  /// Open the hunt config to start (or re-run) a hunt.
  final VoidCallback? onStartHunt;

  /// Lets the host screen step the selection (previous/next shortcuts).
  final ListNavController? navController;

  @override
  Widget build(BuildContext context) => HuntReportPanel(
    noun: 'holes',
    filters: [
      _byType(
        'Uncovered',
        AuditFindingType.uncoveredStrongMove,
        'uncovered strong moves',
      ),
      _byType('Refutations', AuditFindingType.refutation, 'refutations'),
      _byType('Traps', AuditFindingType.practicalTrap, 'practical traps'),
    ],
    gainCpOf: holeGainCp,
    emptyState: const HuntEmptyState(
      icon: Icons.gps_fixed,
      title: 'No hole report yet',
      body:
          'Find Holes attacks these lines from the opposite side — '
          'uncovered replies, verified refutations, and Maia '
          'expectimax traps at end positions — then ranks a short '
          'list of killer holes. Different from Analyze with Engine, '
          'which only colors positions by raw Stockfish eval.',
      actionLabel: 'Find Holes',
    ),
    result: result,
    liveFindings: liveFindings,
    isHunting: isHunting,
    progressMessage: progress?.message,
    skippedPassTooltip: trapPassSkipped
        ? 'Trap search skipped — Maia unavailable'
        : null,
    onFindingSelected: onFindingSelected,
    onResultChanged: onResultChanged,
    onStartHunt: onStartHunt,
    navController: navController,
  );
}
