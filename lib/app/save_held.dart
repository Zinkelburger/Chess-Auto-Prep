import 'package:flutter/material.dart';

import '../workspace/document/copy_name_dialog.dart';
import '../workspace/document/document_session.dart';
import '../workspace/document/study_drafts.dart';
import 'workspace_requests.dart';

/// Save, Ctrl+S and Save changes: the held edits into their file, or, for a
/// file this app may not write, into a copy in [collections] or a new
/// chapter of a study, whichever the user picks.
Future<void> saveHeld(
  BuildContext context, {
  required DocumentSession session,
  required WorkspaceRequests requests,
  required String collections,
}) async {
  if (session.readOnly == null) return session.keepHeld();
  final where = await showDialog<_HeldTarget>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Save your moves'),
      children: [
        for (final target in _HeldTarget.values)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, target),
            child: Text(target.label),
          ),
      ],
    ),
  );
  if (where == null || !context.mounted) return;
  switch (where) {
    case _HeldTarget.copy:
      final name = await showCopyNameDialog(context);
      if (name == null) return;
      sayCopy(requests.say, await session.saveCopy(name, into: collections));
    case _HeldTarget.study:
      await requests.addToStudy([?gameDraft(session)]);
  }
}

enum _HeldTarget {
  copy('Copy into Documents…'),
  study('Add to a study…');

  const _HeldTarget(this.label);
  final String label;
}
