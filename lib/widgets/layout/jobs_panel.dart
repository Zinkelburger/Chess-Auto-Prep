/// Jobs panel for the bottom pane — shows active/completed generation and audit jobs.
///
/// Displays progress for running jobs and generated lines for completed ones.
/// Lines can be clicked to navigate and accepted/rejected to add to repertoire.
library;

import 'package:flutter/material.dart';

import '../../services/jobs/repertoire_job.dart';
import '../../theme/app_colors.dart';

class JobsPanel extends StatelessWidget {
  final JobManager jobManager;
  final bool isGenerating;
  final bool isGenerationPaused;
  final bool isAuditing;
  final VoidCallback? onOpenGenerationDialog;
  final VoidCallback? onPauseGeneration;
  final VoidCallback? onResumeGeneration;
  final VoidCallback? onCancelGeneration;

  const JobsPanel({
    super.key,
    required this.jobManager,
    this.isGenerating = false,
    this.isGenerationPaused = false,
    this.isAuditing = false,
    this.onOpenGenerationDialog,
    this.onPauseGeneration,
    this.onResumeGeneration,
    this.onCancelGeneration,
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
        if (isAuditing && !isGenerating) _buildAuditStatus(context),
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
            child: Text('Cancel',
                style: TextStyle(fontSize: 11, color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  Widget _buildAuditStatus(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.tertiaryContainer.withAlpha(40),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: Theme.of(context).colorScheme.tertiary,
            ),
          ),
          const SizedBox(width: 8),
          const Text('Auditing...',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
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

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(icon, size: 18, color: statusColor),
      title: Text(job.label, style: const TextStyle(fontSize: 12)),
      subtitle: Text(
        '${job.type.name} · ${job.status.name}',
        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
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
