/// Jobs tab body for the repertoire bottom pane.
///
/// Shows one of three surfaces: the inline generation config, the inline
/// audit config, or the jobs list. The host owns the inline-config flags
/// and the pane; this widget only renders and forwards intents.
library;

import 'package:flutter/material.dart';

import '../../constants/chess_constants.dart';
import '../../core/audit_session_controller.dart';
import '../../core/generation_session_controller.dart';
import '../../core/repertoire_controller.dart';
import '../../features/audit/models/audit_finding.dart';
import '../../features/audit/models/audit_result.dart';
import '../../features/audit/widgets/audit_config_panel.dart';
import '../../services/jobs/repertoire_job.dart';
import '../../utils/app_messages.dart';
import '../generation/snapshot_export_dialog.dart';
import '../repertoire_generation_tab.dart';
import 'jobs_panel.dart';

class JobsTabContent extends StatelessWidget {
  final bool showInlineGenConfig;
  final bool showInlineAuditConfig;
  final RepertoireController controller;
  final GenerationSessionController generationController;
  final AuditSessionController auditController;
  final JobManager jobManager;

  /// Lets the host seed the DB explorer after opening the generation config.
  final GlobalKey<RepertoireGenerationTabState>? generationTabKey;

  final VoidCallback onCloseInlineGenConfig;
  final VoidCallback onCloseInlineAuditConfig;
  final VoidCallback onOpenGenerationDialog;

  /// Open the audit config (forceConfig) from the jobs list.
  final VoidCallback onOpenAuditConfig;

  /// Open the coverage config dialog and start a coverage run.
  final VoidCallback? onOpenCoverageDialog;

  // Audit lifecycle callbacks stay host-owned so they can guard on `mounted`
  // (the audit service reports asynchronously and may outlive this widget).
  final void Function(bool auditing) onAuditingChanged;
  final void Function(AuditResult result) onAuditResultReady;
  final void Function(AuditFinding finding) onAuditLiveFinding;
  final void Function(int checked, int total) onAuditProgress;

  const JobsTabContent({
    super.key,
    required this.showInlineGenConfig,
    required this.showInlineAuditConfig,
    required this.controller,
    required this.generationController,
    required this.auditController,
    required this.jobManager,
    this.generationTabKey,
    required this.onCloseInlineGenConfig,
    required this.onCloseInlineAuditConfig,
    required this.onOpenGenerationDialog,
    required this.onOpenAuditConfig,
    this.onOpenCoverageDialog,
    required this.onAuditingChanged,
    required this.onAuditResultReady,
    required this.onAuditLiveFinding,
    required this.onAuditProgress,
  });

  @override
  Widget build(BuildContext context) {
    if (showInlineGenConfig && !generationController.isGenerating) {
      return Column(
        children: [
          _inlineConfigHeader(
            icon: Icons.auto_awesome,
            title: 'Generate Repertoire',
            onClose: onCloseInlineGenConfig,
          ),
          const Divider(height: 1),
          Expanded(
            child: RepertoireGenerationTab(
              key: generationTabKey,
              fen: controller.fen,
              isWhiteRepertoire: controller.isRepertoireWhite,
              currentRepertoire: controller.currentRepertoire,
              currentMoveSequence: controller.currentMoveSequence,
              repertoireStartFen: controller.startingFen ?? kStandardStartFen,
              generationController: generationController,
              onLinesSaved: (lines) {
                controller.appendNewLines([
                  for (final l in lines)
                    (moves: l.moves, title: l.title, pgn: l.pgn),
                ]);
              },
            ),
          ),
        ],
      );
    }

    if (showInlineAuditConfig && !auditController.isAuditing) {
      return Column(
        children: [
          _inlineConfigHeader(
            icon: Icons.policy_outlined,
            title: 'Audit Repertoire',
            onClose: onCloseInlineAuditConfig,
          ),
          const Divider(height: 1),
          Expanded(
            child: AuditConfigPanel(
              openingTree: controller.openingTree,
              isWhiteRepertoire: controller.isRepertoireWhite,
              currentFen: controller.fen,
              currentMoveSequence: controller.currentMoveSequence,
              repertoireFilePath: controller.currentRepertoire?.filePath,
              auditService: auditController.service,
              onConfigChanged: auditController.onConfigChanged,
              onAuditingChanged: onAuditingChanged,
              onResultReady: onAuditResultReady,
              onLiveFinding: onAuditLiveFinding,
              onProgress: onAuditProgress,
            ),
          ),
        ],
      );
    }

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

  Widget _inlineConfigHeader({
    required IconData icon,
    required String title,
    required VoidCallback onClose,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
      child: Row(
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClose,
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }
}
