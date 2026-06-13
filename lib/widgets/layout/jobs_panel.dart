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
  final VoidCallback? onOpenAuditDialog;
  final VoidCallback? onPauseGeneration;
  final VoidCallback? onResumeGeneration;
  final VoidCallback? onCancelGeneration;
  final VoidCallback? onFinishNowGeneration;
  final VoidCallback? onPauseAudit;
  final VoidCallback? onResumeAudit;
  final VoidCallback? onCancelAudit;

  // Generation progress details
  final String genProgressStatus;
  final int genNodes;
  final int genDepth;
  final double? genNodesPerMinute;
  final double? genEtaSec;
  final int genElapsedMs;

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
    this.onOpenAuditDialog,
    this.onPauseGeneration,
    this.onResumeGeneration,
    this.onCancelGeneration,
    this.onFinishNowGeneration,
    this.onPauseAudit,
    this.onResumeAudit,
    this.onCancelAudit,
    this.genProgressStatus = '',
    this.genNodes = 0,
    this.genDepth = 0,
    this.genNodesPerMinute,
    this.genEtaSec,
    this.genElapsedMs = 0,
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
          Icon(Icons.work_outline, size: 40, color: Colors.grey[700]),
          const SizedBox(height: 12),
          Text('No active jobs',
              style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Generate a repertoire or audit an existing one',
              style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          const SizedBox(height: 20),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: onOpenGenerationDialog,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('Generate'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: onOpenAuditDialog,
                icon: const Icon(Icons.policy_outlined, size: 16),
                label: const Text('Audit'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGenerationStatus(BuildContext context) {
    final rate = genNodesPerMinute;
    final elapsed = Duration(milliseconds: genElapsedMs);
    final etaStr = genEtaSec != null && genEtaSec! > 0
        ? _formatDuration(Duration(seconds: genEtaSec!.round()))
        : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.primaryContainer.withAlpha(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row: status + controls
          Row(
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
              Expanded(
                child: Text(
                  isGenerationPaused
                      ? 'Paused — $genNodes nodes at depth $genDepth'
                      : genProgressStatus.isNotEmpty
                          ? genProgressStatus
                          : 'Generating...',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
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
              if (onFinishNowGeneration != null)
                Tooltip(
                  message: 'Stop exploring and build lines from '
                      'what\'s been found so far',
                  child: TextButton(
                    onPressed: onFinishNowGeneration,
                    child: Text('Finish Now',
                        style: TextStyle(
                            fontSize: 11, color: Colors.orange[300])),
                  ),
                ),
              TextButton(
                onPressed: onCancelGeneration,
                child: const Text('Cancel',
                    style: TextStyle(fontSize: 11, color: AppColors.danger)),
              ),
            ],
          ),
          // Progress stats row
          if (genNodes > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: DefaultTextStyle(
                style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: Colors.grey[500]),
                child: Row(
                  children: [
                    Text('depth $genDepth'),
                    const SizedBox(width: 12),
                    Text('$genNodes nodes'),
                    if (rate != null && rate > 0) ...[
                      const SizedBox(width: 12),
                      Text('${rate.toStringAsFixed(0)} n/min'),
                    ],
                    const SizedBox(width: 12),
                    Text(_formatDuration(elapsed)),
                    if (etaStr != null) ...[
                      const SizedBox(width: 12),
                      Text('ETA $etaStr'),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
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
    final statusLabel = switch (job.status) {
      JobStatus.running => 'Running',
      JobStatus.paused => 'Paused',
      JobStatus.completed => 'Completed',
      JobStatus.failed => 'Failed',
      JobStatus.cancelled => 'Cancelled',
      JobStatus.queued => 'Queued',
    };
    final typeLabel = job.type == JobType.generation
        ? 'Generation'
        : 'Audit';

    final subtitleParts = <String>[typeLabel, statusLabel];
    if (job.type == JobType.audit && job.configSnapshot != null) {
      try {
        final cfg = AuditConfig.fromMap(job.configSnapshot!);
        subtitleParts.add(cfg.summaryLabel);
      } catch (_) {}
    }
    if (job.subtreeFen != null && job.subtreeFen != 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1') {
      subtitleParts.add('from subtree');
    }

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(icon, size: 18, color: statusColor),
      title: Text(job.label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
      subtitle: Text(
        subtitleParts.join(' · '),
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
          : Icon(
              job.status == JobStatus.completed
                  ? Icons.check_circle_outline
                  : job.status == JobStatus.failed
                      ? Icons.error_outline
                      : Icons.cancel_outlined,
              size: 16,
              color: statusColor),
    );
  }
}
