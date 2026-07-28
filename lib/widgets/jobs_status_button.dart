import 'package:flutter/material.dart';

import '../services/jobs/repertoire_job.dart';
import '../theme/app_colors.dart';

/// App-bar button showing background jobs (tactics imports, generation,
/// audits, coverage) from any screen, with a Cancel action per job.
///
/// Always present so the app bar keeps a constant layout; a small badge dot
/// appears while anything is running, and with nothing running the menu
/// simply says so.
class JobsStatusButton extends StatelessWidget {
  const JobsStatusButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: JobManager.instance,
      builder: (context, _) {
        final manager = JobManager.instance;
        final active = manager.activeJobs;
        return PopupMenuButton<void>(
          tooltip: manager.statusSummary ?? 'Background jobs',
          icon: Badge(
            isLabelVisible: active.isNotEmpty,
            smallSize: 8,
            child: const Icon(Icons.work_outline),
          ),
          itemBuilder: (context) => [
            if (active.isEmpty)
              const PopupMenuItem<void>(
                enabled: false,
                child: Text('No background jobs running'),
              ),
            for (final job in active)
              PopupMenuItem<void>(enabled: false, child: _JobMenuRow(job: job)),
          ],
        );
      },
    );
  }
}

class _JobMenuRow extends StatelessWidget {
  const _JobMenuRow({required this.job});

  final RepertoireJob job;

  @override
  Widget build(BuildContext context) {
    final message = job.progress.message;
    final onCancel = job.onCancel;
    return SizedBox(
      width: 340,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Explicit styles: the popup item renders as disabled (it is
                // not itself tappable — only the Cancel button is), and the
                // greyed disabled text style would read as inactive.
                Text(
                  job.label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (message.isNotEmpty)
                  Text(
                    message,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.onSurfaceMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onCancel == null
                ? null
                : () {
                    onCancel();
                    Navigator.pop(context);
                  },
            child: const Text(
              'Cancel',
              style: TextStyle(fontSize: 12, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}
