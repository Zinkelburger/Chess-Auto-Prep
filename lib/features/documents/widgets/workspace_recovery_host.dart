import 'package:flutter/material.dart';
import '../../../design_system/components/confirm_dialog.dart';
import '../../../design_system/theme/app_spacing.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../controllers/document_close_coordinator.dart';
import 'document_close_scope.dart';
import '../controllers/workspace_recovery_controller.dart';

/// Startup recovery is discoverable before the workspace's reader is mounted.
class WorkspaceRecoveryHost<T> extends StatelessWidget {
  const WorkspaceRecoveryHost({
    super.key,
    required this.recovery,
    required this.onRestored,
    required this.child,
    required this.id,
    required this.workspaceName,
    required this.title,
    required this.path,
  });
  final WorkspaceRecoveryController<T> recovery;
  final VoidCallback onRestored;
  final Widget child;
  final String id;
  final String workspaceName;
  final String Function(T snapshot) title;
  final String Function(T snapshot) path;

  Future<void> _review(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: recovery,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(l10n.workspaceRecoveryTitle(workspaceName)),
          scrollable: true,
          content: SizedBox(
            width: AppSpacing.formWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.workspaceRecoveryExplanation),
                if (recovery.actionError != null)
                  Text(
                    l10n.workspaceRecoveryActionFailed,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                for (final entry in recovery.listing.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          title(entry.snapshot),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (path(entry.snapshot).isNotEmpty)
                          Text(path(entry.snapshot)),
                        Text(
                          l10n.workspaceRecoveryTimestamp(
                            MaterialLocalizations.of(
                              context,
                            ).formatFullDate(entry.updatedAt.toLocal()),
                            MaterialLocalizations.of(context).formatTimeOfDay(
                              TimeOfDay.fromDateTime(entry.updatedAt.toLocal()),
                            ),
                          ),
                        ),
                        Wrap(
                          spacing: AppSpacing.sm,
                          children: [
                            FilledButton(
                              key: ValueKey(('restore-$id-recovery', entry.id)),
                              onPressed: recovery.busy
                                  ? null
                                  : () async {
                                      final restored = await recovery.restore(
                                        entry,
                                      );
                                      if (!context.mounted || !restored) {
                                        return;
                                      }
                                      Navigator.pop(context);
                                      onRestored();
                                    },
                              child: Text(l10n.restoreWorkspaceRecovery),
                            ),
                            TextButton(
                              onPressed: recovery.busy
                                  ? null
                                  : () async {
                                      final confirmed = await confirmAction(
                                        context,
                                        title: l10n.dismissWorkspaceRecovery,
                                        message: l10n
                                            .dismissWorkspaceRecoveryQuestion,
                                        confirmLabel:
                                            l10n.dismissWorkspaceRecovery,
                                      );
                                      if (confirmed && context.mounted) {
                                        await recovery.dismiss(entry);
                                      }
                                    },
                              child: Text(l10n.dismissWorkspaceRecovery),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.keepEditing),
            ),
          ],
        );
      },
    ),
  );
  @override
  Widget build(BuildContext context) => DocumentCloseRegistration(
    revision: () => 0,
    prepare: () async {
      await recovery.flush();
      return const DocumentCloseApproval(0);
    },
    child: ListenableBuilder(
      listenable: recovery,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        final failure =
            recovery.writeError != null || recovery.readError != null;
        final unreadable = recovery.listing.unreadable > 0;
        final entries = recovery.listing.entries;
        return Column(
          children: [
            if (failure || unreadable || entries.isNotEmpty)
              MaterialBanner(
                content: Text(
                  failure
                      ? l10n.workspaceRecoveryUnavailable(workspaceName)
                      : unreadable
                      ? l10n.workspaceRecoveryUnreadable(workspaceName)
                      : l10n.workspaceRecoveryAvailable(
                          workspaceName,
                          entries.length,
                        ),
                ),
                actions: [
                  if (entries.isNotEmpty)
                    TextButton(
                      key: ValueKey('review-$id-recovery'),
                      onPressed: recovery.busy ? null : () => _review(context),
                      child: Text(l10n.reviewWorkspaceRecovery),
                    ),
                  if (failure || unreadable)
                    TextButton(
                      onPressed: recovery.busy
                          ? null
                          : () async {
                              try {
                                await recovery.flush();
                              } catch (_) {
                                /* Banner retains error. */
                              }
                              await recovery.refresh();
                            },
                      child: Text(l10n.retryWorkspaceRecovery),
                    ),
                ],
              ),
            Expanded(key: ValueKey('$id-recovery-workspace'), child: child),
          ],
        );
      },
    ),
  );
}
