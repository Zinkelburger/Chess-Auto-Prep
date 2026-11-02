import 'package:flutter/material.dart';

import '../../storage/chapter_files.dart';
import '../../ui/name_dialog.dart';
import '../../workspace/document/document_session.dart';
import 'chapter_outline.dart';
import 'library.dart';
import 'library_messages.dart';
import 'library_state.dart';
import 'new_chapter_dialog.dart';

/// The builder's two ways to make something, which the list's buttons and
/// the Actions menu both run.
///
/// One question, the name. Which side a repertoire is for is asked when its
/// chapter opens, which is now: the new repertoire opens at once.
Future<void> newRepertoire(
  BuildContext context,
  Library library,
  ValueChanged<ChapterRef> onOpen,
) async {
  final name = await showNameDialog(
    context,
    title: 'Create repertoire',
    label: 'Repertoire name',
    confirm: 'Create',
  );
  if (name == null || !context.mounted) return;
  final result = await announce(
    context,
    library.createRepertoire(name),
    thing: 'repertoire',
    name: name,
    failed: 'Could not create the repertoire.',
  );
  if (!context.mounted || result is! LibraryAdded) return;
  onOpen(result.first);
}

/// A chapter in the open repertoire, starting from the moves on the board
/// when they are asked for.
Future<void> newChapter(
  BuildContext context,
  Library library,
  ChapterOutline outline,
  DocumentSession session,
) async {
  final into = outline.repertoire;
  final chapter = session.chapter;
  if (into == null) return;
  final wanted = await showNewChapterDialog(
    context,
    fromBoard: chapter == null
        ? null
        : rootMovesFromBoard(chapter, session.cursor.value),
  );
  if (wanted == null || !context.mounted) return;
  await announce(
    context,
    library.createChapter(into, wanted.name, rootMoves: wanted.rootMoves),
    thing: 'chapter',
    name: wanted.name,
    failed: 'Could not create the chapter.',
  );
}
