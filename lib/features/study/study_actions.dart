import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../storage/chapter_files.dart';
import '../../ui/confirm_dialog.dart';
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

/// The whole-study commands of the study panel's toolbar and rows, over
/// [studies] and the open [session]: each opens what it asks with, then
/// hands what became of it to [became], or says to [say] why nothing
/// happened.
final class StudyCommands {
  const StudyCommands({
    required this.studies,
    required this.session,
    required this.became,
    required this.say,
    this.onLichessLogin,
  });

  final Studies studies;
  final DocumentSession session;
  final StudyOutcome became;
  final ValueChanged<String> say;

  /// The Lichess login, for a send that needs one; true once logged in.
  final Future<bool> Function(BuildContext)? onLichessLogin;

  bool get busy => studies.busy;
  bool get hasOpenStudy => studies.open != null;

  /// The app can write to Lichess.
  bool get canSend => studies.sender != null;

  /// The open study's one pending write that failed, its save or its
  /// rename, tried again; null when neither failed.
  VoidCallback? get retry {
    if (studies.canRetrySave) {
      return () => unawaited(studies.retrySave().then(became));
    }
    if (studies.canRetryRename) {
      return () => unawaited(studies.retryRename().then(became));
    }
    return null;
  }

  Future<void> create(BuildContext context) =>
      newStudy(context, studies, became);

  Future<void> importInto(BuildContext context) =>
      importChapters(context, studies, became);

  Future<void> send(BuildContext context) =>
      sendStudyToLichess(context, studies, session, onLogIn: onLichessLogin);

  Future<void> addChapter(BuildContext context) =>
      newStudyChapter(context, session, say);

  Future<void> rename(BuildContext context) async {
    final study = studies.open;
    if (study == null) return;
    final name = await showNameDialog(
      context,
      title: 'Rename study',
      label: 'Study name',
      confirm: 'Rename',
      initial: study.name,
    );
    if (name == null || !context.mounted) return;
    became(await studies.rename(study, name));
  }

  Future<void> exportPgn(BuildContext context) async {
    final study = studies.open;
    if (study == null) return;
    final name = await showNameDialog(
      context,
      title: 'Export study PGN',
      label: 'File name',
      confirm: 'Choose folder',
      initial: study.name,
    );
    if (name == null || !context.mounted) return;
    if (studies.open != study) {
      say('The open study changed. Export it again.');
      return;
    }
    became(await studies.exportPgn(name));
  }

  /// The open study, when there is one.
  Future<void> deleteOpen(BuildContext context) async {
    if (studies.open case final open?) await delete(context, open);
  }

  Future<void> delete(BuildContext context, ChapterRef study) async {
    final yes = await confirmAction(
      context,
      title: 'Delete study “${study.name}”?',
      message:
          'The PGN file, with every chapter in it, will be moved to Chess '
          'Auto Prep recovery storage.',
      confirm: 'Delete',
    );
    if (!yes || !context.mounted) return;
    became(await studies.delete(study));
  }

  Future<void> copyOpen() => copy(studies.pgnOfOpenStudy());

  /// [pgn] on the clipboard once read, or why there is nothing to copy.
  Future<void> copy(Future<String?> pgn) async {
    final text = await pgn;
    if (text == null) {
      say('There is nothing to copy.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
  }
}
