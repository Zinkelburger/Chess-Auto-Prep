/// Banner shown when an interrupted audit can be resumed, extracted from
/// `AuditFindingsPanel`.
library;

import 'package:flutter/material.dart';

import '../services/audit_persistence.dart';

class AuditResumeBanner extends StatelessWidget {
  const AuditResumeBanner({
    super.key,
    required this.snapshot,
    required this.onResume,
    required this.onStartFresh,
  });

  final AuditSnapshot snapshot;
  final VoidCallback? onResume;
  final VoidCallback? onStartFresh;

  @override
  Widget build(BuildContext context) {
    final checked = snapshot.result.nodesChecked;
    final findings = snapshot.result.findings.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.amber.withAlpha(20),
        border: Border(
          bottom: BorderSide(color: Colors.amber.withAlpha(60)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.pause_circle_outline, size: 16, color: Colors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Audit interrupted at $checked positions ($findings findings)',
              style: const TextStyle(fontSize: 11, color: Colors.amber),
            ),
          ),
          TextButton(
            onPressed: onResume,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 11),
            ),
            child: const Text('Resume'),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: onStartFresh,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 11),
              foregroundColor: Colors.grey,
            ),
            child: const Text('Start Fresh'),
          ),
        ],
      ),
    );
  }
}
