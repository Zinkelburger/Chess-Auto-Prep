/// Jobs tab body for the repertoire bottom pane: the list of running and
/// finished jobs, plus the buttons that open a new one.
///
/// It used to double as a host for the generation and audit config forms,
/// which is why the pane needed flags for which of three surfaces it was
/// showing. Both forms are full-screen routes now ([BuildConfigScreen]), so
/// this is one surface again.
library;

import 'package:flutter/material.dart';

import '../../features/audit/controllers/audit_session_controller.dart';
import '../../core/generation_session_controller.dart';
import '../../core/repertoire_controller.dart';
import '../../services/jobs/repertoire_job.dart';
import '../../utils/app_messages.dart';
import '../generation/snapshot_export_dialog.dart';
import 'jobs_panel.dart';

class JobsTabContent extends StatelessWidget {
  final RepertoireController controller;
  final GenerationSessionController generationController;
  final AuditSessionController auditController;
  final JobManager jobManager;

  final VoidCallback onOpenGenerationDialog;

  /// Open the audit config (forceConfig) from the jobs list.
  final VoidCallback onOpenAuditConfig;

  /// Open the coverage config dialog and start a coverage run.
  final VoidCallback? onOpenCoverageDialog;

  const JobsTabContent({
    super.key,
    required this.controller,
    required this.generationController,
    required this.auditController,
    required this.jobManager,
    required this.onOpenGenerationDialog,
    required this.onOpenAuditConfig,
    this.onOpenCoverageDialog,
  });

  @override
  Widget build(BuildContext context) {
    final gc = generationController;
    return ListenableBuilder(
      listenable: Listenable.merge([jobManager, gc, auditController]),
      builder: (context, _) => JobsPanel(
        jobManager: jobManager,
        generationController: gc,
        auditController: auditController,
        onOpenGenerationDialog: onOpenGenerationDialog,
        onOpenAuditDialog: onOpenAuditConfig,
        onOpenCoverageDialog: onOpenCoverageDialog,
        onPauseAudit: auditController.pause,
        onResumeAudit: auditController.resume,
        onCancelAudit: () =>
            auditController.cancel(controller.currentRepertoire?.filePath),
        onPauseGeneration: gc.pauseBuild,
        onResumeGeneration: gc.resumeBuild,
        onCancelGeneration: gc.cancelBuild,
        onFinishNowGeneration: gc.finishNow,
        onExportLinesGeneration: () => _exportSnapshot(context, gc),
      ),
    );
  }

  /// Ask for a new repertoire name (+ verify choice) and export the lines
  /// the build has found so far.  The run continues either way.
  Future<void> _exportSnapshot(
    BuildContext context,
    GenerationSessionController gc,
  ) async {
    final config = gc.activeConfig;
    final choice = await showSnapshotExportDialog(
      context,
      suggestedName: gc.snapshotNameSuggestion(),
      canVerify: config?.needsStockfish ?? false,
      verifyDepth: config?.resolvedVerifyDepth,
    );
    if (choice == null) return;
    final (ok, message) = await gc.exportSnapshot(
      repertoireName: choice.name,
      verify: choice.verify,
    );
    if (context.mounted) {
      showAppSnackBar(context, message, isError: !ok);
    }
  }
}
