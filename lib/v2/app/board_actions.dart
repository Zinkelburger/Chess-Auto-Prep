import 'dart:async';

import 'package:flutter/material.dart';

import '../features/library/library.dart';
import '../features/study/studies.dart';
import '../storage/chapter_files.dart';
import '../ui/app_action.dart';
import '../ui/choice_dialog.dart';
import '../ui/name_dialog.dart';
import '../workspace/document_session.dart';
import 'workspace_requests.dart';

/// The analysis board's doors in the Actions menu: back to it, a new one
/// from the position on the board, and — while it is up — a paste onto it
/// and the two ways to keep it. Each way to keep it asks two questions, one
/// dialog each: where, then what to call it.
List<AppAction> boardActions(
  BuildContext context, {
  required DocumentSession session,
  required WorkspaceRequests requests,
  required Library library,
  required Studies studies,
}) {
  final scratch = session.isScratch;
  return [
    AppAction(
      'Analysis board',
      scratch ? null : () => unawaited(requests.analysisBoard()),
    ),
    AppAction(
      'New analysis board from here',
      () => unawaited(requests.newAnalysisBoard()),
      shortcut: 'Ctrl+N',
    ),
    if (scratch) ...[
      AppAction(
        'Paste PGN or FEN',
        () => unawaited(requests.pasteOntoBoard()),
        shortcut: 'Ctrl+V',
      ),
      AppAction(
        'Save to repertoire…',
        () => unawaited(_toRepertoire(context, requests, library)),
        group: 'Document',
      ),
      AppAction(
        'Save to study…',
        () => unawaited(_toStudy(context, requests, studies)),
        group: 'Document',
      ),
    ],
  ];
}

Future<void> _toRepertoire(
  BuildContext context,
  WorkspaceRequests requests,
  Library library,
) async {
  final into = await showChoiceDialog<RepertoireFolder>(
    context,
    title: 'Save to repertoire',
    options: library.repertoires,
    label: (folder) => folder.name,
    hint: 'Type a repertoire',
    empty: 'No repertoires yet',
  );
  if (into == null || !context.mounted) return;
  final name = await _chapterName(context, into.name);
  if (name == null) return;
  await requests.saveBoardToRepertoire(into, name);
}

Future<void> _toStudy(
  BuildContext context,
  WorkspaceRequests requests,
  Studies studies,
) async {
  final study = await showChoiceDialog<ChapterRef>(
    context,
    title: 'Save to study',
    options: studies.studies,
    label: (study) => study.name,
    hint: 'Type a study',
    empty: 'No studies yet',
  );
  if (study == null || !context.mounted) return;
  final name = await _chapterName(context, study.name);
  if (name == null) return;
  await requests.saveBoardToStudy(study, name);
}

Future<String?> _chapterName(BuildContext context, String into) async {
  if (!context.mounted) return null;
  return showNameDialog(
    context,
    title: 'New chapter in $into',
    label: 'Chapter name',
    confirm: 'Save',
  );
}
