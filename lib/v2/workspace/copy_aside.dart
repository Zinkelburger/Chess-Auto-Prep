import 'package:path/path.dart' as p;

import '../storage/chapter_files.dart';
import 'document_saver.dart';
import 'document_session.dart';
import 'save_state.dart';
import 'session_results.dart';

/// Writes the draft on screen beside its file as `<name>.pgn`, replacing
/// nothing. A copy changes nothing in the session, so nothing goes stale:
/// whatever the user opened meanwhile, the answer is about the file they
/// asked for.
///
/// A document that can still take words keeps the session; one frozen by a
/// stopped save, or that this app may not write, hands it over, because the
/// copy is the only place those words can go on being edited. A conflicted
/// document keeps it: it can still be reloaded.
Future<CopyResult> saveCopy(
  DocumentSession session,
  DocumentSaver saver,
  String name,
) async {
  final written = await copyAside(session, saver, name);
  if (written is! CopySaved) return written;
  final ref = session.source;
  final frozen = saver.state is SaveStopped || session.readOnly != null;
  if (ref == null || !frozen) return written;
  final path = p.join(p.dirname(ref.path), written.name);
  final opened = await session.open(ChapterRef.at(path), game: session.game);
  return CopySaved(written.name, nowEditing: opened is DocumentOpened);
}

/// Writes the words on screen beside their file and leaves the session
/// where it is, which is what the question on the way out asks for: the
/// user is going somewhere else, so the copy is not what they want open.
Future<CopyResult> copyAside(
  DocumentSession session,
  DocumentSaver saver,
  String name,
) async {
  final ref = session.source;
  final chapter = session.chapter;
  if (ref == null || chapter == null) {
    return const CopyFailed('there is nothing open to copy');
  }
  return saver.copyAside(chapter, beside: ref, name: name);
}
