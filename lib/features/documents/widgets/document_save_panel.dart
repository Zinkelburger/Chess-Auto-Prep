import 'package:flutter/material.dart';

import '../../../design_system/components/save_status.dart';
import '../../../design_system/theme/app_spacing.dart';
import '../../../design_system/theme/app_typography.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../repositories/document_save_actions.dart';
import '../models/document_save_state.dart';
import '../models/pgn_document.dart';

/// Reusable interaction over the session contract. The host owns the editor,
/// destination picker and session lifetime. Dismissing a dialog only dismisses.
class DocumentSavePanel extends StatelessWidget {
  const DocumentSavePanel({
    super.key,
    required this.session,
    required this.chooseCopyDestination,
    required this.focusEditor,
  });
  final DocumentSaveActions session;
  final Future<String?> Function(BuildContext) chooseCopyDestination;
  final VoidCallback focusEditor;

  Future<void> _copy(BuildContext context) async {
    final destination = await chooseCopyDestination(context);
    if (!context.mounted || destination == null) return;
    await session.saveCopy(destination);
  }

  Future<void> _inspect(BuildContext context) async {
    final result = await session.inspectCurrent();
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.inspectCurrentDocument),
        scrollable: true,
        content: SelectableText(switch (result) {
          PgnOpened(:final snapshot) => snapshot.content,
          PgnMissing() => l10n.documentMissing,
          PgnReadFailed() => l10n.documentReadFailed,
        }),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.closeDocumentInspection),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<DocumentSaveState>(
    stream: session.changes,
    initialData: session.state,
    builder: (context, _) {
      // Current state also covers a host swapping sessions before the new
      // stream emits. The stream is only the invalidation signal.
      final state = session.state;
      final l10n = AppLocalizations.of(context);
      final problem = switch (state.phase) {
        DocumentSavePhase.conflict ||
        DocumentSavePhase.collision ||
        DocumentSavePhase.failed ||
        DocumentSavePhase.uncertain => true,
        _ => false,
      };
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            state.path,
            key: const ValueKey('document-save-path'),
            style: AppTypography.caption(context),
          ),
          const SizedBox(height: AppSpacing.sm),
          SaveStatus(
            message: switch (state.phase) {
              DocumentSavePhase.clean => l10n.documentClean,
              DocumentSavePhase.dirty => l10n.documentDirty,
              DocumentSavePhase.saving => l10n.documentSaving,
              DocumentSavePhase.saved => l10n.documentSaved,
              DocumentSavePhase.conflict => l10n.documentConflict,
              DocumentSavePhase.collision => l10n.documentCollision,
              DocumentSavePhase.failed => l10n.documentSaveFailed,
              DocumentSavePhase.uncertain => l10n.documentSaveUncertain,
              DocumentSavePhase.reloading => l10n.documentReloading,
            },
            busy: state.busy,
            tone: problem ? SaveStatusTone.error : SaveStatusTone.normal,
            actions: [
              FilledButton(
                key: const ValueKey('document-save'),
                onPressed: state.canSave ? session.save : null,
                child: Text(l10n.saveChanges),
              ),
              TextButton(
                key: const ValueKey('document-save-copy'),
                onPressed: state.busy ? null : () => _copy(context),
                child: Text(l10n.saveCopy),
              ),
              if (problem) ...[
                TextButton(
                  onPressed: state.busy
                      ? null
                      : () {
                          session.keepEditing();
                          focusEditor();
                        },
                  child: Text(l10n.keepEditing),
                ),
                TextButton(
                  onPressed: state.busy ? null : () => _inspect(context),
                  child: Text(l10n.inspectCurrentDocument),
                ),
                TextButton(
                  onPressed: state.busy ? null : session.reloadPreservingDraft,
                  child: Text(l10n.reloadPreservingDraft),
                ),
              ],
            ],
          ),
          if (state.readFailure != null) ...[
            const SizedBox(height: AppSpacing.sm),
            SaveStatus(
              message: state.readFailure is PgnMissing
                  ? l10n.documentMissing
                  : l10n.documentReadFailed,
              tone: SaveStatusTone.error,
            ),
          ],
          if (state.retainedDrafts.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            SaveStatus(
              message: l10n.documentDraftRetained,
              actions: [
                for (
                  var index = 0;
                  index < state.retainedDrafts.length;
                  index++
                )
                  TextButton(
                    onPressed: state.busy
                        ? null
                        : () async {
                            await session.restoreDraft(index);
                            if (context.mounted &&
                                session.state.readFailure == null) {
                              focusEditor();
                            }
                          },
                    child: Text(
                      state.retainedDrafts.length == 1
                          ? l10n.restoreRetainedDraft
                          : l10n.restoreRetainedDraftNumber(index + 1),
                    ),
                  ),
              ],
            ),
          ],
        ],
      );
    },
  );
}
