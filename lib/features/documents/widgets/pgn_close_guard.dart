import 'package:flutter/material.dart';
import '../controllers/document_close_coordinator.dart';
import '../repositories/document_save_actions.dart';
import 'document_close_scope.dart';
import 'document_save_dialog.dart';

/// App-level approval for the PGN owner, including before its reader is mounted.
class PgnCloseGuard extends StatelessWidget {
  const PgnCloseGuard({
    super.key,
    required this.actions,
    required this.revision,
    required this.flush,
    required this.chooseCopyDestination,
    required this.child,
  });
  final DocumentSaveActions actions;
  final Object Function() revision;
  final Future<void> Function() flush;
  final Future<String?> Function(BuildContext) chooseCopyDestination;
  final Widget child;
  Future<DocumentCloseApproval?> _prepare(BuildContext context) async {
    await flush();
    if (!context.mounted) return null;
    final currentRevision = revision();
    if (!actions.state.needsResolution) {
      return DocumentCloseApproval(currentRevision);
    }
    final choice = await showDocumentLeaveDialog(
      context,
      session: actions,
      revision: revision,
      chooseCopyDestination: chooseCopyDestination,
    );
    // Another participant can still cancel. Approval never discards the draft.
    if (choice == null) return null;
    await flush();
    return DocumentCloseApproval(choice.revision);
  }

  @override
  Widget build(BuildContext context) => DocumentCloseRegistration(
    revision: revision,
    prepare: () => _prepare(context),
    child: child,
  );
}
