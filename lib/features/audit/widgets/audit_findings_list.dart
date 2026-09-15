/// Scrollable findings list (with empty/auditing states) for the audit panel,
/// extracted from `AuditFindingsPanel`.
///
/// Owns only presentation: it delegates each row to [FindingTile] and reports
/// selection / dismiss / context-menu intents back to the panel via callbacks.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../models/audit_finding.dart';
import 'finding_style.dart';
import 'finding_tile.dart';

class AuditFindingsList extends StatelessWidget {
  const AuditFindingsList({
    super.key,
    required this.findings,
    required this.isAuditing,
    required this.scrollController,
    required this.selectedIndex,
    required this.onStartAudit,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.emptyActionLabel,
    required this.onSelect,
    required this.onToggleDismiss,
    required this.onContextMenu,
  });

  /// The currently-visible findings (already filtered/sorted/capped).
  final List<AuditFinding> findings;
  final bool isAuditing;
  final ScrollController scrollController;
  final int selectedIndex;
  final VoidCallback? onStartAudit;
  final String emptyTitle;
  final String emptyMessage;
  final String emptyActionLabel;
  final void Function(int index) onSelect;
  final void Function(AuditFinding finding) onToggleDismiss;
  final void Function(AuditFinding finding, Offset position) onContextMenu;

  @override
  Widget build(BuildContext context) {
    if (findings.isEmpty) {
      if (isAuditing) {
        return const Center(
          child: Text(
            'Auditing...',
            style: TextStyle(color: AppColors.onSurfaceMuted, fontSize: 12),
          ),
        );
      }
      return Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.fact_check_outlined,
                  size: 40,
                  color: AppColors.onSurfaceDim,
                ),
                const SizedBox(height: 12),
                Text(
                  emptyTitle,
                  style: const TextStyle(
                    color: AppColors.onSurfaceSoft,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  emptyMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.onSurfaceMuted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 16),
                if (onStartAudit != null)
                  OutlinedButton.icon(
                    onPressed: onStartAudit,
                    icon: const Icon(Icons.policy_outlined, size: 16),
                    label: Text(emptyActionLabel),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      itemCount: findings.length,
      itemExtent: 56,
      itemBuilder: (context, index) {
        final finding = findings[index];
        return FindingTile(
          finding: finding,
          isSelected: index == selectedIndex,
          color: findingColor(finding),
          icon: findingIcon(finding),
          onSelect: () => onSelect(index),
          onToggleDismiss: () => onToggleDismiss(finding),
          onContextMenu: (pos) => onContextMenu(finding, pos),
        );
      },
    );
  }
}
