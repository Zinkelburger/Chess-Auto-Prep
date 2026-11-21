import 'package:flutter/material.dart';

import '../ui/options_dialog.dart';
import '../workspace/document/document_session.dart';
import '../workspace/document/save_copy.dart';
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
  if (session.readOnly == null) {
    if (!session.keepHeld()) {
      requests.say('The file cannot take your edits yet. They stay unsaved.');
    }
    return;
  }
  final source = CopySource(session);
  final game = session.game;
  final where = await showOptionsDialog(
    context,
    title: 'Save your moves',
    options: [for (final target in _HeldTarget.values) (target, target.label)],
  );
  if (where == null || !context.mounted) return;
  // A file opened or read again while a dialog was up is not what the user
  // chose to save, nor, for a study, another game of it.
  switch (where) {
    case _HeldTarget.copy:
      final name = await askCopyName(context);
      if (name == null) return;
      sayCopy(
        requests.say,
        source.matches(session)
            ? await session.saveCopy(name, into: collections)
            : copyOvertaken,
      );
    case _HeldTarget.study:
      if (!source.matches(session) || session.game != game) {
        return requests.say(
          'The document changed while you chose. Nothing was added.',
        );
      }
      await requests.addToStudy([?gameDraft(session)]);
  }
}

enum _HeldTarget {
  copy('Copy into Documents…'),
  study('Add to a study…');

  const _HeldTarget(this.label);
  final String label;
}
