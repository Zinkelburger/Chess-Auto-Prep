/// Shared color/icon styling for [AuditFinding] rows, used by both the
/// audit findings list and the hole-hunt report panel.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../models/audit_finding.dart';

Color findingColor(AuditFinding finding) {
  if (finding.type == AuditFindingType.missingResponse &&
      finding.source == MissingResponseSource.clash) {
    return Colors.purple;
  }
  return switch (finding.type) {
    AuditFindingType.mistake => AppColors.evalNegative,
    AuditFindingType.inaccuracy => Colors.orange,
    AuditFindingType.missingResponse => Colors.blue,
    AuditFindingType.weakPosition => Colors.deepOrange,
    AuditFindingType.deadEnd => AppColors.onSurfaceMuted,
    AuditFindingType.uncoveredStrongMove => Colors.cyan,
    AuditFindingType.refutation => AppColors.evalNegative,
    AuditFindingType.practicalTrap => Colors.purpleAccent,
  };
}

IconData findingIcon(AuditFinding finding) {
  if (finding.type == AuditFindingType.missingResponse &&
      finding.source == MissingResponseSource.clash) {
    return Icons.menu_book_outlined;
  }
  return switch (finding.type) {
    AuditFindingType.mistake => Icons.error_outline,
    AuditFindingType.inaccuracy => Icons.warning_amber_outlined,
    AuditFindingType.missingResponse => Icons.visibility_off_outlined,
    AuditFindingType.weakPosition => Icons.trending_down,
    AuditFindingType.deadEnd => Icons.block_outlined,
    AuditFindingType.uncoveredStrongMove => Icons.gps_fixed,
    AuditFindingType.refutation => Icons.bolt,
    AuditFindingType.practicalTrap => Icons.psychology_alt_outlined,
  };
}
