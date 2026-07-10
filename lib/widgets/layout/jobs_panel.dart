/// Jobs panel for the bottom pane — shows active/completed generation and audit jobs.
///
/// Each running job is a single compact card with phase, live stats, resource
/// usage, progress, and controls. Completed jobs use a simpler list tile.
library;

import 'package:flutter/material.dart';

import '../../core/audit_session_controller.dart';
import '../../core/generation_session_controller.dart';
import '../../features/audit/services/audit_config.dart';
import '../../services/generation/generation_config.dart';
import '../../services/jobs/generation_job_display.dart';
import '../../services/jobs/repertoire_job.dart';
import '../../theme/app_colors.dart';

class JobsPanel extends StatelessWidget {
  final JobManager jobManager;
  final GenerationSessionController generationController;
  final AuditSessionController auditController;
  final VoidCallback? onOpenGenerationDialog;
  final VoidCallback? onOpenAuditDialog;
  final VoidCallback? onOpenCoverageDialog;
  final VoidCallback? onPauseGeneration;
  final VoidCallback? onResumeGeneration;
  final VoidCallback? onCancelGeneration;
  final VoidCallback? onFinishNowGeneration;
  final VoidCallback? onPauseAudit;
  final VoidCallback? onResumeAudit;
  final VoidCallback? onCancelAudit;

  const JobsPanel({
    super.key,
    required this.jobManager,
    required this.generationController,
    required this.auditController,
    this.onOpenGenerationDialog,
    this.onOpenAuditDialog,
    this.onOpenCoverageDialog,
    this.onPauseGeneration,
    this.onResumeGeneration,
    this.onCancelGeneration,
    this.onFinishNowGeneration,
    this.onPauseAudit,
    this.onResumeAudit,
    this.onCancelAudit,
  });

  @override
  Widget build(BuildContext context) {
    final jobs = jobManager.jobs;
    final active = jobManager.activeJobs;
    final completed = jobManager.completedJobs;
    final isGenerating = generationController.isGenerating;
    final isAuditing = auditController.isAuditing;

    if (jobs.isEmpty && !isGenerating && !isAuditing) {
      return _buildEmptyState(context);
    }

    final activeCards = <Widget>[];
    for (final job in active) {
      if (job.type == JobType.generation &&
          isGenerating &&
          job == generationController.currentJob) {
        activeCards.add(_buildGenerationJobCard(context, job));
      } else if (job.type == JobType.audit &&
          isAuditing &&
          job == auditController.currentJob) {
        activeCards.add(_buildAuditJobCard(context, job));
      } else if (job.type == JobType.coverage) {
        activeCards.add(_buildCoverageJobCard(context, job));
      } else {
        activeCards.add(_buildJobTile(context, job));
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        ...activeCards,
        if (completed.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Text(
                  'Completed',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[500],
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => jobManager.clearCompleted(),
                  child: const Text('Clear', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ),
          for (final job in completed) _buildJobTile(context, job),
        ],
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
          Text(
            'No active jobs',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Generate a repertoire or audit an existing one',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
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
              if (onOpenCoverageDialog != null) ...[
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: onOpenCoverageDialog,
                  icon: const Icon(Icons.analytics_outlined, size: 16),
                  label: const Text('Coverage'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGenerationJobCard(BuildContext context, RepertoireJob job) {
    final gc = generationController;
    final phase = gc.progressPhase;
    final config = gc.activeConfig ?? _configFromJob(job);
    final statsLine = buildGenerationStatsLine(
      phase: phase,
      nodes: gc.progressNodes,
      currentDepth: gc.progressDepth,
      maxPlyConfig: gc.progressMaxPlyConfig,
      unexploredAtDepth: gc.progressUnexploredAtDepth,
      totalAtDepth: gc.progressTotalAtDepth,
      nodesPerMinute: gc.progressNodesPerMinute,
      etaDepthSec: gc.progressEtaSec?.round(),
      linesExtracted: gc.progressLines,
    );
    final fraction = generationProgressFraction(
      phase: phase,
      currentDepth: gc.progressDepth,
      maxPlyConfig: gc.progressMaxPlyConfig,
      unexploredAtDepth: gc.progressUnexploredAtDepth,
      totalAtDepth: gc.progressTotalAtDepth,
    );
    final elapsed = formatJobDuration(
      Duration(milliseconds: gc.progressElapsedMs),
    );
    final resourceLabel = generationResourceLabel(config);
    final configSummary = config?.summaryLabel;
    final accent = Theme.of(context).colorScheme.primary;

    return _ActiveJobCard(
      icon: Icons.auto_awesome,
      accent: accent,
      title: job.label,
      subtitle: configSummary,
      phaseIcon: phase.icon,
      phaseLabel: phase.label,
      statsLine: statsLine,
      elapsed: elapsed,
      resourceLabel: resourceLabel,
      progress: fraction,
      isPaused: gc.isPaused,
      onPause: onPauseGeneration,
      onResume: onResumeGeneration,
      onCancel: onCancelGeneration,
      extraActions: onFinishNowGeneration != null &&
              phase == GenerationPhase.buildingTree
          ? [
              Tooltip(
                message: 'Stop exploring and build lines from '
                    'what\'s been found so far',
                child: TextButton(
                  onPressed: onFinishNowGeneration,
                  child: Text(
                    'Finish Now',
                    style: TextStyle(fontSize: 11, color: Colors.orange[300]),
                  ),
                ),
              ),
            ]
          : null,
    );
  }

  Widget _buildAuditJobCard(BuildContext context, RepertoireJob job) {
    final ac = auditController;
    final fraction = ac.totalNodes > 0
        ? ac.nodesChecked / ac.totalNodes
        : null;
    final statsLine = ac.totalNodes > 0
        ? '${ac.nodesChecked} / ${ac.totalNodes} positions checked'
        : 'Starting audit…';
    final configSummary = ac.lastConfig?.summaryLabel ??
        _auditConfigFromJob(job)?.summaryLabel;
    final accent = Theme.of(context).colorScheme.tertiary;

    return _ActiveJobCard(
      icon: Icons.policy_outlined,
      accent: accent,
      title: job.label,
      subtitle: configSummary,
      phaseIcon: Icons.search,
      phaseLabel: 'Auditing',
      statsLine: statsLine,
      elapsed: null,
      resourceLabel: null,
      progress: fraction,
      isPaused: ac.isPaused,
      onPause: onPauseAudit,
      onResume: onResumeAudit,
      onCancel: onCancelAudit,
    );
  }

  Widget _buildCoverageJobCard(BuildContext context, RepertoireJob job) {
    final accent = Theme.of(context).colorScheme.secondary;
    return _ActiveJobCard(
      icon: Icons.analytics_outlined,
      accent: accent,
      title: job.label,
      subtitle: null,
      phaseIcon: Icons.analytics_outlined,
      phaseLabel: 'Analyzing coverage',
      statsLine: job.progress.message.isNotEmpty
          ? job.progress.message
          : 'Starting analysis…',
      elapsed: null,
      resourceLabel: null,
      progress: job.progress.fraction > 0 ? job.progress.fraction : null,
      isPaused: false,
      onPause: null,
      onResume: null,
      onCancel: null,
    );
  }

  TreeBuildConfig? _configFromJob(RepertoireJob job) {
    final snap = job.configSnapshot;
    if (snap == null) return null;
    try {
      return TreeBuildConfig.fromJson(
        snap,
        startFen: job.subtreeFen ??
            'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );
    } catch (_) {
      return null;
    }
  }

  AuditConfig? _auditConfigFromJob(RepertoireJob job) {
    final snap = job.configSnapshot;
    if (snap == null) return null;
    try {
      return AuditConfig.fromMap(snap);
    } catch (_) {
      return null;
    }
  }

  Widget _buildJobTile(BuildContext context, RepertoireJob job) {
    final icon = switch (job.type) {
      JobType.generation => Icons.auto_awesome,
      JobType.audit => Icons.policy_outlined,
      JobType.coverage => Icons.analytics_outlined,
    };
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

    final subtitleParts = <String>[statusLabel];
    if (job.progress.message.isNotEmpty) {
      subtitleParts.add(job.progress.message);
    } else if (job.type == JobType.audit && job.configSnapshot != null) {
      final cfg = _auditConfigFromJob(job);
      if (cfg != null) subtitleParts.add(cfg.summaryLabel);
    } else if (job.type == JobType.generation && job.configSnapshot != null) {
      final cfg = _configFromJob(job);
      if (cfg != null) subtitleParts.add(cfg.summaryLabel);
    }

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(icon, size: 18, color: statusColor),
      title: Text(
        job.label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        subtitleParts.join(' · '),
        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(
        job.status == JobStatus.completed
            ? Icons.check_circle_outline
            : job.status == JobStatus.failed
                ? Icons.error_outline
                : Icons.cancel_outlined,
        size: 16,
        color: statusColor,
      ),
    );
  }
}

class _ActiveJobCard extends StatelessWidget {
  const _ActiveJobCard({
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.phaseIcon,
    required this.phaseLabel,
    required this.statsLine,
    required this.elapsed,
    required this.resourceLabel,
    required this.progress,
    required this.isPaused,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    this.extraActions,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String? subtitle;
  final IconData phaseIcon;
  final String phaseLabel;
  final String statsLine;
  final String? elapsed;
  final String? resourceLabel;
  final double? progress;
  final bool isPaused;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;
  final List<Widget>? extraActions;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: accent.withAlpha(28),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withAlpha(48)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: isPaused
                    ? Icon(Icons.pause_circle_filled,
                        size: 16, color: Colors.orange[300])
                    : CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: accent,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(icon, size: 14, color: accent),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (elapsed != null)
                          Text(
                            elapsed!,
                            style: TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              color: Colors.grey[500],
                            ),
                          ),
                      ],
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (isPaused && onResume != null)
                TextButton(
                  onPressed: onResume,
                  child: const Text('Resume', style: TextStyle(fontSize: 11)),
                )
              else if (!isPaused && onPause != null)
                TextButton(
                  onPressed: onPause,
                  child: const Text('Pause', style: TextStyle(fontSize: 11)),
                ),
              ...?extraActions,
              if (onCancel != null)
                TextButton(
                  onPressed: onCancel,
                  child: const Text(
                    'Cancel',
                    style: TextStyle(fontSize: 11, color: AppColors.danger),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(phaseIcon, size: 13, color: accent.withAlpha(200)),
              const SizedBox(width: 5),
              Text(
                phaseLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: accent.withAlpha(220),
                ),
              ),
              if (resourceLabel != null) ...[
                const SizedBox(width: 8),
                _StatChip(label: resourceLabel!, color: accent),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            statsLine,
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: Colors.grey[400],
              height: 1.3,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress!.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: Colors.grey[850],
                color: accent,
              ),
            ),
          ] else if (!isPaused) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                minHeight: 3,
                backgroundColor: Colors.grey[850],
                color: accent,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(32),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(64)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 9, color: color.withAlpha(220)),
      ),
    );
  }
}
