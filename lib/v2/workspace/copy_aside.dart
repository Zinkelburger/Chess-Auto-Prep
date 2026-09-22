import 'package:path/path.dart' as p;

import '../chess/pgn/chapter.dart';
import '../storage/document_ref.dart';
import '../storage/pgn_document_store.dart' as store;
import 'session_results.dart';

/// Writes [chapter] into a new file next to [beside], under [name].
///
/// This is the one way out of a document that can take no more words — a
/// save the store stopped, a file this app may not write, a conflict the
/// user does not want to lose their draft to. It replaces nothing: the name
/// being taken is a result, never permission to overwrite.
Future<CopyResult> copyChapterAside(
  store.PgnDocumentStore documents,
  Chapter chapter, {
  required DocumentRef beside,
  required String name,
}) async {
  final file = p.extension(name) == '.pgn' ? name : '$name.pgn';
  final target = DocumentRef(p.join(p.dirname(beside.path), file));
  return switch (await documents.create(target, writeChapter(chapter))) {
    store.Created() => CopySaved(file),
    store.Collision() => const CopyNameTaken(),
    store.IoFailure(:final detail) => CopyFailed(detail),
  };
}
