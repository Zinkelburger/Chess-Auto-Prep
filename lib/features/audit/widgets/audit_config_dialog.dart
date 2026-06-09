/// Modal dialog wrapping [AuditConfigPanel] for audit configuration.
///
/// Opened from the toolbar audit button or the A shortcut key.
/// Contains audit config and starts the audit on Start.
library;

import 'package:flutter/material.dart';

import '../../../models/opening_tree.dart';
import '../models/audit_finding.dart';
import '../models/audit_result.dart';
import 'audit_config_panel.dart';

/// Shows the audit config dialog.
Future<void> showAuditConfigDialog(
  BuildContext context, {
  required OpeningTree? openingTree,
  required bool isWhiteRepertoire,
  required String currentFen,
  required List<String> currentMoveSequence,
  String? repertoireFilePath,
  required void Function(bool) onAuditingChanged,
  required void Function(AuditResult) onResultReady,
  void Function(AuditFinding)? onLiveFinding,
  GlobalKey<AuditConfigPanelState>? auditConfigKey,
}) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.policy_outlined, size: 20),
                  const SizedBox(width: 8),
                  Text('Audit Repertoire',
                      style: Theme.of(dialogCtx).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(dialogCtx).pop(),
                  ),
                ],
              ),
            ),
            const Divider(),
            Flexible(
              child: AuditConfigPanel(
                key: auditConfigKey,
                openingTree: openingTree,
                isWhiteRepertoire: isWhiteRepertoire,
                currentFen: currentFen,
                currentMoveSequence: currentMoveSequence,
                repertoireFilePath: repertoireFilePath,
                onAuditingChanged: (auditing) {
                  onAuditingChanged(auditing);
                  if (auditing) {
                    Navigator.of(dialogCtx).pop();
                  }
                },
                onResultReady: onResultReady,
                onLiveFinding: onLiveFinding,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
