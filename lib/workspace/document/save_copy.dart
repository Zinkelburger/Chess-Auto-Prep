import 'package:flutter/material.dart';

import '../../chess/pgn/chapter.dart';
import '../../storage/chapter_files.dart';
import '../../ui/name_dialog.dart';
import '../../ui/status_bar.dart';
import 'document_session.dart';
import 'session_results.dart';

/// The file and PGN contents the user started copying. Selecting another
/// game shares the same lines and preamble that [writeChapter] writes.
final class CopySource {
  CopySource(DocumentSession session)
    : _chapter = session.snapshot(),
      _source = session.source;

  final Chapter? _chapter;
  final ChapterRef? _source;

  bool matches(DocumentSession session) =>
      session.source == _source &&
      session.chapter?.preamble == _chapter?.preamble &&
      identical(session.chapter?.lines, _chapter?.lines);
}

/// What a Save a copy came to, in the words every place that offers one
/// (the edit strip, the Actions menu, the question on the way out) shows.
String copySaid(CopyResult result) => switch (result) {
  CopySaved(:final name, nowEditing: true) =>
    'Saved a copy as $name. Now editing the copy.',
  CopySaved(:final name) => 'Saved a copy as $name',
  CopyNameTaken() => 'That name is taken. Nothing was replaced.',
  CopyFailed(:final detail) => 'Could not save a copy: $detail',
};

/// Puts what a Save a copy came to in the status bar: a saved copy is where
/// the user's work went, not a problem.
void sayCopy(Say say, CopyResult result) =>
    say(copySaid(result), problem: result is! CopySaved);

/// Asks what to call the copy, refusing a name no file could take.
/// Returns null when the user backs out.
Future<String?> askCopyName(BuildContext context) => showNameDialog(
  context,
  title: 'Save a copy',
  label: 'File name',
  confirm: 'Save a copy',
);
