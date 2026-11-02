import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../ui/name_dialog.dart';
import '../../workspace/document/document_session.dart';
import 'new_chapter_dialog.dart';
import 'studies.dart';
import 'studies_state.dart';
import 'study_commands.dart';
import 'study_import_dialog.dart';
import 'study_send_dialog.dart';

/// What became of a change to the studies: one sentence when it did not
/// happen, the study it opened when it did.
typedef StudyOutcome = void Function(StudyResult result);

/// The study panel's main commands, which the Actions menu offers too: the
/// same dialogs whichever of the two they are asked from.
Future<void> newStudy(
  BuildContext context,
  Studies studies,
  StudyOutcome became,
) async {
  final name = await showNameDialog(
    context,
    title: 'New study',
    label: 'Study name',
    confirm: 'Create',
  );
  if (name == null || !context.mounted) return;
  became(await studies.create(name));
}

/// Chapters from a file or Lichess: into the open study, or a new one.
Future<void> importChapters(
  BuildContext context,
  Studies studies,
  StudyOutcome became,
) async {
  final result = await showStudyImport(
    context,
    studies,
    append: studies.open != null,
  );
  if (result != null && context.mounted) became(result);
}

/// The open chapter to a Lichess study.
Future<void> sendStudyToLichess(
  BuildContext context,
  Studies studies,
  DocumentSession session, {
  Future<bool> Function(BuildContext)? onLogIn,
}) async {
  final sender = studies.sender;
  final chapter = session.snapshot();
  final study = studies.open;
  if (sender == null || chapter == null || study == null) return;
  await showSendToLichess(
    context,
    sender: sender,
    study: chapter,
    name: study.name,
    onLogIn: onLogIn,
  );
}

/// A chapter at the end of the open study; [refused] hears the sentence
/// when it could not be added.
Future<void> newStudyChapter(
  BuildContext context,
  DocumentSession session,
  ValueChanged<String> refused,
) async {
  final wanted = await showNewChapterDialog(context);
  if (wanted == null || !context.mounted) return;
  final refusal = addStudyChapter(
    session,
    name: wanted.name,
    orientation:
        wanted.orientation ??
        (wanted.root.whiteToMove ? Side.white : Side.black),
    root: wanted.root,
  );
  if (refusal != null) refused(refusal);
}
