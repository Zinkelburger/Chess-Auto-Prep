import 'package:flutter/material.dart';

import '../../chess/pgn/chapter.dart';
import '../../storage/chapter_files.dart';
import '../../ui/name_dialog.dart';
import '../../ui/status_bar.dart';
import '../latest.dart';
import 'document_session.dart';
import 'session_results.dart';

/// The document a Save a copy was asked for. The copy is named in a dialog,
/// and a file opened from the desktop or read again meanwhile is not what
/// the user named, so the copy is written only while [matches]. Edits made
/// in the same document meanwhile, such as a review writing its games, are
/// still this document and go into the copy.
final class CopySource {
  CopySource(DocumentSession session)
    : _source = session.source,
      _opened = session.openTicket,
      _chapter = session.chapter;

  final ChapterRef? _source;
  final Ticket _opened;
  final Chapter? _chapter;

  /// Whether [session] still shows the document named: nothing was read
  /// into it since, or what was read is the same file with the same words.
  bool matches(DocumentSession session) {
    if (session.source != _source) return false;
    if (_opened.current) return true;
    final now = session.chapter;
    final then = _chapter;
    return identical(now, then) ||
        (now != null && then != null && _sameWords(now, then));
  }
}

/// Whether [a] and [b] hold the same words, game by game, without writing
/// either file out: a large one would stall the window.
bool _sameWords(Chapter a, Chapter b) {
  if (a.preamble != b.preamble || a.lines.length != b.lines.length) {
    return false;
  }
  for (final (i, line) in a.lines.indexed) {
    final other = b.lines[i];
    if (identical(line, other)) continue;
    if (line.text != other.text || line.trailer != other.trailer) return false;
  }
  return true;
}

/// What a copy whose document changed under its dialog came to.
const copyOvertaken = CopyFailed(
  'the document changed while the copy was named',
);

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
