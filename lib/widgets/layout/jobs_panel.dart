/// Jobs panel for the bottom pane — shows active/completed generation and audit jobs.
///
/// Displays progress for running jobs and generated lines for completed ones.
/// Lines can be clicked to navigate and accepted/rejected to add to repertoire.
library;

import 'package:flutter/material.dart';

import '../../features/audit/services/audit_config.dart';
import '../../services/jobs/repertoire_job.dart';
import '../../theme/app_colors.dart';

class JobsPanel extends StatelessWidget {
  final JobManager jobManager;
  final bool isGenerating;
  final bool isGenerationPaused;
  final bool isAuditing;
  final bool isAuditPaused;
  final int auditNodesChecked;
  final int auditTotalNodes;
  final AuditConfig? lastAuditConfig;
  final VoidCallback? onOpenGenerationDialog;
  final VoidCallback? onPauseGeneration;
  final VoidCallback? onResumeGeneration;
  final VoidCallback? onCancelGeneration;
  final VoidCallback? onPauseAudit;
  final VoidCallback? onResumeAudit;
  final VoidCallback? onCancelAudit;

  const JobsPanel({
    super.key,
    required this.jobManager,
    this.isGenerating = false,
    this.isGenerationPaused = false,
    this.isAuditing = false,
    this.isAuditPaused = false,
    this.auditNodesChecked = 0,
    this.auditTotalNodes = 0,
    this.lastAuditConfig,
    this.onOpenGenerationDialog,
    this.onPauseGeneration,
    this.onResumeGeneration,
    this.onCancelGeneration,
    this.onPauseAudit,
    this.onResumeAudit,
    this.onCancelAudit,
  });

  @override
  Widget build(BuildContext context) {
    final jobs = jobManager.jobs;
    final active = jobManager.activeJobs;
    final completed = jobManager.completedJobs;

    if (jobs.isEmpty && !isGenerating && !isAuditing) {
      return _buildEmptyState(context);
    }

    return Column(
      children: [
        if (isGenerating) _buildGenerationStatus(context),
        if (isAuditing) _buildAuditStatus(context),
        if (active.isNotEmpty || completed.isNotEmpty)
          Expanded(
            child: ListView(
              children: [
                for (final job in active) _buildJobTile(context, job),
                if (completed.isNotEmpty) ...[
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Row(
                      children: [
                        Text('Completed',
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[500],
                                fontWeight: FontWeight.w600)),
                        const Spacer(),
                        TextButton(
                          onPressed: () => jobManager.clearCompleted(),
                          child: const Text('Clear',
                              style: TextStyle(fontSize: 11)),
                        ),
                      ],
                    ),
                  ),
                  for (final job in completed) _buildJobTile(context, job),
                ],
              ],
            ),
          )
        else
          const Expanded(child: SizedBox.shrink()),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.work_outline, size: 32, color: Colors.grey[600]),
          const SizedBox(height: 8),
          Text('No active jobs',
              style: TextStyle(color: Colors.grey[500], fontSize: 13)),
          const SizedBox(height: 4),
          Text('Generate lines from the toolbar or nav bar',
              style: TextStyle(color: Colors.grey[600], fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildGenerationStatus(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.primaryContainer.withAlpha(40),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: isGenerationPaused
                ? Icon(Icons.pause, size: 14, color: Colors.orange[300])
                : CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Theme.of(context).colorScheme.primary,
                  ),
          ),
          const SizedBox(width: 8),
          Text(
            isGenerationPaused ? 'Generation paused' : 'Generating...',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const Spacer(),
          if (isGenerationPaused)
            TextButton(
              onPressed: onResumeGeneration,
              child: const Text('Resume', style: TextStyle(fontSize: 11)),
            )
          else
            TextButton(
              onPressed: onPauseGeneration,
              child: const Text('Pause', style: TextStyle(fontSize: 11)),
            ),
          TextButton(
            onPressed: onCancelGeneration,
            child: const Text('Cancel',
                style: TextStyle(fontSize: 11, color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  Widget _buildAuditStatus(BuildContext context) {
    final fraction = auditTotalNodes > 0
        ? auditNodesChecked / auditTotalNodes
        : 0.0;
    final progressText = auditTotalNodes > 0
        ? '$auditNodesChecked / $auditTotalNodes positions'
        : 'Starting audit...';
    final configSummary = lastAuditConfig?.summaryLabel;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.tertiaryContainer.withAlpha(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: isAuditPaused
                    ? Icon(Icons.pause, size: 14, color: Colors.orange[300])
                    : CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isAuditPaused ? 'Audit paused' : 'Auditing — $progressText',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isAuditPaused)
                TextButton(
                  onPressed: onResumeAudit,
                  child: const Text('Resume', style: TextStyle(fontSize: 11)),
                )
              else
                TextButton(
                  onPressed: onPauseAudit,
                  child: const Text('Pause', style: TextStyle(fontSize: 11)),
                ),
              TextButton(
                onPressed: onCancelAudit,
                child: const Text('Cancel',
                    style: TextStyle(fontSize: 11, color: AppColors.danger)),
              ),
            ],
          ),
          if (auditTotalNodes > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 3,
                  backgroundColor: Colors.grey[800],
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ),
            ),
          if (configSummary != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                configSummary,
                style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildJobTile(BuildContext context, RepertoireJob job) {
    final icon = job.type == JobType.generation
        ? Icons.auto_awesome
        : Icons.policy_outlined;
    final statusColor = switch (job.status) {
      JobStatus.running => Theme.of(context).colorScheme.primary,
      JobStatus.paused => Colors.orange,
      JobStatus.completed => AppColors.success,
      JobStatus.failed => AppColors.danger,
      JobStatus.cancelled => Colors.grey,
      JobStatus.queued => Colors.grey,
    };

    final subtitle = StringBuffer('${job.type.name} · ${job.status.name}');
    if (job.type == JobType.audit && job.configSnapshot != null) {
      try {
        final cfg = AuditConfig.fromMap(job.configSnapshot!);
        subtitle.write(' · ${cfg.summaryLabel}');
      } catch (_) {}
    }

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(icon, size: 18, color: statusColor),
      title: Text(job.label, style: const TextStyle(fontSize: 12)),
      subtitle: Text(
        subtitle.toString(),
        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: job.isActive
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: statusColor),
            )
          : Icon(Icons.check_circle_outline, size: 16, color: statusColor),
    );
  }
}
