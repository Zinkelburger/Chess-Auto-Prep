/// Horizontal type-filter chip row for the audit findings panel, extracted
/// from `AuditFindingsPanel`.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../models/audit_finding.dart';

class AuditFilterBar extends StatelessWidget {
  const AuditFilterBar({
    super.key,
    required this.findings,
    required this.activeFilters,
    required this.onToggle,
    this.clashOnly = false,
    this.onToggleClashOnly,
  });

  /// All findings (the chip counts exclude dismissed ones).
  final List<AuditFinding> findings;

  /// Currently-active type filters (empty = show all).
  final Set<AuditFindingType> activeFilters;

  /// Toggle a type filter on/off.
  final void Function(AuditFindingType type) onToggle;

  /// When true, only clash-sourced missing responses are shown.
  final bool clashOnly;

  /// Toggle the clash-only source filter.
  final VoidCallback? onToggleClashOnly;

  @override
  Widget build(BuildContext context) {
    if (findings.isEmpty) return const SizedBox.shrink();

    int countOf(AuditFindingType t) =>
        findings.where((f) => f.type == t && !f.dismissed).length;

    final clashCount = findings
        .where(
          (f) =>
              f.type == AuditFindingType.missingResponse &&
              f.source == MissingResponseSource.clash &&
              !f.dismissed,
        )
        .length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _typeChip(
              label: 'Blunders',
              count: countOf(AuditFindingType.mistake),
              type: AuditFindingType.mistake,
              color: AppColors.evalNegative,
            ),
            const SizedBox(width: 4),
            _typeChip(
              label: 'Inaccuracies',
              count: countOf(AuditFindingType.inaccuracy),
              type: AuditFindingType.inaccuracy,
              color: AppColors.findingInaccuracy,
            ),
            const SizedBox(width: 4),
            _typeChip(
              label: 'Missing',
              count: countOf(AuditFindingType.missingResponse),
              type: AuditFindingType.missingResponse,
              color: AppColors.findingMissingResponse,
            ),
            if (clashCount > 0) ...[
              const SizedBox(width: 4),
              _chip(
                label: 'Clashes',
                count: clashCount,
                color: AppColors.findingClash,
                isActive: clashOnly,
                onSelected: onToggleClashOnly,
              ),
            ],
            const SizedBox(width: 4),
            _typeChip(
              label: 'Weak',
              count: countOf(AuditFindingType.weakPosition),
              type: AuditFindingType.weakPosition,
              color: AppColors.findingWeakPosition,
            ),
            const SizedBox(width: 4),
            _typeChip(
              label: 'Dead Ends',
              count: countOf(AuditFindingType.deadEnd),
              type: AuditFindingType.deadEnd,
              color: AppColors.onSurfaceMuted,
            ),
          ],
        ),
      ),
    );
  }

  /// One colour-coded filter toggle.
  ///
  /// Both the finding-type chips and the source chips are this shape; they
  /// were two methods that differed only in how the tap arrived.
  Widget _chip({
    required String label,
    required int count,
    required Color color,
    required bool isActive,
    required VoidCallback? onSelected,
    bool showZeroCount = true,
  }) {
    return FilterChip(
      label: Text(
        count > 0 || showZeroCount ? '$label ($count)' : label,
        style: TextStyle(fontSize: 12, color: isActive ? AppColors.ink : color),
      ),
      selected: isActive,
      selectedColor: color.withAlpha(80),
      backgroundColor: Colors.transparent,
      side: BorderSide(color: isActive ? color : color.withAlpha(60), width: 1),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      showCheckmark: false,
      onSelected: onSelected != null ? (_) => onSelected() : null,
    );
  }

  /// A finding-type chip: active from [activeFilters], disabled at zero, and
  /// labelled without the count when there is none.
  Widget _typeChip({
    required String label,
    required int count,
    required AuditFindingType type,
    required Color color,
  }) => _chip(
    label: label,
    count: count,
    color: color,
    isActive: activeFilters.contains(type),
    showZeroCount: false,
    onSelected: count > 0 ? () => onToggle(type) : null,
  );
}
