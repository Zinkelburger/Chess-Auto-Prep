import 'package:flutter/material.dart';
import '../../../design_system/components/confirm_dialog.dart';
import '../../../design_system/theme/app_spacing.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../documents/controllers/document_close_coordinator.dart';
import '../../documents/widgets/document_close_scope.dart';
import '../controllers/study_recovery_controller.dart';

/// Startup recovery is discoverable in every mode, including before Study opens.
class StudyRecoveryHost extends StatelessWidget {
  const StudyRecoveryHost({
    super.key,
    required this.recovery,
    required this.onRestored,
    required this.child,
  });
  final StudyRecoveryController recovery;
  final VoidCallback onRestored;
  final Widget child;

  Future<void> _review(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: recovery,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(l10n.studyRecoveryTitle),
          scrollable: true,
          content: SizedBox(
            width: AppSpacing.formWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.studyRecoveryExplanation),
                if (recovery.actionError != null)
                  Text(
                    l10n.studyRecoveryActionFailed,
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
                          entry.snapshot.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (entry.snapshot.path.isNotEmpty)
                          Text(entry.snapshot.path),
                        Text(
                          l10n.studyRecoveryTimestamp(
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
                              key: ValueKey((
                                'restore-study-recovery',
                                entry.id,
                              )),
                              onPressed: recovery.busy
                                  ? null
                                  : () async {
                                      await recovery.restore(entry);
                                      if (!context.mounted ||
                                          recovery.actionError != null) {
                                        return;
                                      }
                                      Navigator.pop(context);
                                      onRestored();
                                    },
                              child: Text(l10n.restoreStudyRecovery),
                            ),
                            TextButton(
                              onPressed: recovery.busy
                                  ? null
                                  : () async {
                                      final confirmed = await confirmAction(
                                        context,
                                        title: l10n.dismissStudyRecovery,
                                        message:
                                            l10n.dismissStudyRecoveryQuestion,
                                        confirmLabel: l10n.dismissStudyRecovery,
                                      );
                                      if (confirmed && context.mounted) {
                                        await recovery.dismiss(entry);
                                      }
                                    },
                              child: Text(l10n.dismissStudyRecovery),
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
                      ? l10n.studyRecoveryUnavailable
                      : unreadable
                      ? l10n.studyRecoveryUnreadable
                      : l10n.studyRecoveryAvailable(entries.length),
                ),
                actions: [
                  if (entries.isNotEmpty)
                    TextButton(
                      key: const ValueKey('review-study-recovery'),
                      onPressed: recovery.busy ? null : () => _review(context),
                      child: Text(l10n.reviewStudyRecovery),
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
                      child: Text(l10n.retryStudyRecovery),
                    ),
                ],
              ),
            Expanded(key: const ValueKey('recovery-workspace'), child: child),
          ],
        );
      },
    ),
  );
}
