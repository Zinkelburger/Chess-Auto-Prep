/// Scrollable findings list (with empty/auditing states) for the audit panel,
/// extracted from `AuditFindingsPanel`.
///
/// Owns only presentation: it delegates each row to [FindingTile] and reports
/// selection / dismiss / context-menu intents back to the panel via callbacks.
library;

import 'package:flutter/material.dart';

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
  final void Function(int index) onSelect;
  final void Function(AuditFinding finding) onToggleDismiss;
  final void Function(AuditFinding finding, Offset position) onContextMenu;

  @override
  Widget build(BuildContext context) {
    if (findings.isEmpty) {
      if (isAuditing) {
        return Center(
          child: Text('Auditing...',
              style: TextStyle(color: Colors.grey[500], fontSize: 12)),
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_outlined, size: 40, color: Colors.grey[700]),
            const SizedBox(height: 12),
            Text('No audit findings',
                style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'Run an audit to check your repertoire for gaps, '
              'weak moves, and missing responses.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            const SizedBox(height: 16),
            if (onStartAudit != null)
              OutlinedButton.icon(
                onPressed: onStartAudit,
                icon: const Icon(Icons.policy_outlined, size: 16),
                label: const Text('Start Audit'),
              ),
          ],
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
