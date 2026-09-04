/// Ranked trick-hunt report for the Tricks tab.
///
/// The list, the cap, the dismissal and the stepping are [HuntReportPanel],
/// shared with the hole hunt. What is here is what makes it the *trick*
/// report: findings split by whether the move is a novelty, and a gain read
/// straight off the finding.
library;

import 'package:flutter/material.dart';

import '../../../widgets/common/list_nav.dart';
import '../../audit/models/audit_finding.dart';
import '../../audit/models/audit_result.dart';
import '../../audit/widgets/hunt_report_panel.dart';
import '../services/trick_hunt_service.dart';

class TricksReportPanel extends StatelessWidget {
  const TricksReportPanel({
    super.key,
    required this.result,
    required this.liveFindings,
    required this.isHunting,
    this.progress,
    this.probesSkipped = false,
    this.onFindingSelected,
    this.onResultChanged,
    this.onStartHunt,
    this.navController,
  });

  final AuditResult? result;
  final List<AuditFinding> liveFindings;
  final bool isHunting;
  final TrickHuntProgress? progress;

  /// Show the "probes skipped" note (Maia unavailable).
  final bool probesSkipped;

  final void Function(AuditFinding finding)? onFindingSelected;
  final void Function(AuditResult result)? onResultChanged;

  /// Open the hunt config to start (or re-run) a hunt.
  final VoidCallback? onStartHunt;

  /// Lets the host screen step the selection (previous/next shortcuts).
  final ListNavController? navController;

  @override
  Widget build(BuildContext context) => HuntReportPanel(
    noun: 'tricks',
    filters: [
      HuntFilter(
        label: 'Novelties',
        matches: (f) => f.isNovelty == true,
        dismissAllLabel: 'novelties',
      ),
      HuntFilter(
        label: 'In their games',
        matches: (f) => f.isNovelty != true,
        dismissAllLabel: 'in-game tricks',
      ),
    ],
    gainCpOf: (f) {
      final score = f.exploitScore;
      final p = f.cumulativeProbability;
      if (score != null && p != null && p > 0) return (score / p).round();
      return f.netGainCp;
    },
    emptyState: const HuntEmptyState(
      icon: Icons.auto_fix_high,
      title: 'No trick report yet',
      body:
          'Find Tricks plays the opposite side of these games and hunts '
          'for near-best moves and novelties that score better in '
          'practice than the engine-best move, because the likely '
          'replies run into trouble a few moves deeper. Different from '
          'Find Holes, which attacks only what the games already play.',
      actionLabel: 'Find Tricks',
    ),
    result: result,
    liveFindings: liveFindings,
    isHunting: isHunting,
    progressMessage: progress?.message,
    skippedPassTooltip: probesSkipped
        ? 'Probes skipped — Maia unavailable'
        : null,
    onFindingSelected: onFindingSelected,
    onResultChanged: onResultChanged,
    onStartHunt: onStartHunt,
    navController: navController,
  );
}
