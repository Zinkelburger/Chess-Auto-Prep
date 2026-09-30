import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'document_ref.dart';
import 'file_lock.dart';
import 'recovery_files.dart' show discardLeftoverStage;
import 'recovery_quarantine.dart';

/// Edits held in the PGN Viewer and not saved, kept beside the app so a
/// crash, a kill or a window closed on them does not lose them.
///
/// Only a copy: the file itself is written by the user's Save, through the
/// document store. A checkpoint names the revision the edits were made
/// against, so a restored draft is saved with the same check any other
/// save has — a file changed since is a conflict, never an overwrite.
final class ViewerDraft {
  const ViewerDraft({
    required this.path,
    required this.game,
    required this.revision,
    required this.text,
  });

  /// The file the edits belong to, absolute.
  final String path;

  /// The game of it that was on the board.
  final int game;

  /// What the file held when the edits started.
  final Revision revision;

  /// The whole file with the edits in it.
  final String text;
}

/// Where the checkpoints live. The filesystem is a real boundary, so this
/// is an interface: [ViewerDraftFiles] in the app, an in-memory one in a
/// test.
abstract interface class ViewerDrafts {
  /// Keeps [draft] in place of any earlier one for its file. Throws when it
  /// could not be written; the caller logs it and tries again next time.
  Future<void> keep(ViewerDraft draft);

  /// The draft kept for [path], or null when there is none. One that cannot
  /// be read is set aside, never obeyed, and answers null.
  Future<ViewerDraft?> find(String path);

  /// Forgets the draft for [path]: its edits were saved or discarded.
  Future<void> drop(String path);

  /// Moves the draft for [path] into the recovery quarantine, whole: newer
  /// edits are taking its place and it may hold work nothing else has.
  Future<void> setAside(String path);
}

/// One JSON file per document under `<support>/viewer-drafts/`, named by a
/// hash of the document's path, written whole and atomically.
final class ViewerDraftFiles implements ViewerDrafts {
  ViewerDraftFiles(Directory support)
    : _support = support,
      _folder = Directory(p.join(support.path, folder));

  /// The folder under Support.
  static const folder = 'viewer-drafts';

  /// The record's format; any other is set aside rather than read.
  static const version = 1;

  final Directory _support;
  final Directory _folder;

  File _fileFor(String path) =>
      File(p.join(_folder.path, '${sha256.convert(utf8.encode(path))}.json'));

  @override
  Future<void> keep(ViewerDraft draft) async {
    final record = {
      'version': version,
      'path': draft.path,
      'game': draft.game,
      'revision': draft.revision.contentHash,
      'text': draft.text,
    };
    // Encoding a large collection would hold the window.
    final bytes = draft.text.length < _offThreadFrom
        ? utf8.encode(jsonEncode(record))
        : await Isolate.run(() => utf8.encode(jsonEncode(record)));
    await _folder.create(recursive: true);
    await withDirectoryLock(_folder, () async {
      final file = _fileFor(draft.path);
      await discardLeftoverStage(file.path);
      await replaceFile(file.path, bytes);
    });
  }

  @override
  Future<ViewerDraft?> find(String path) async {
    final file = _fileFor(path);
    try {
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      final draft = text.length < _offThreadFrom
          ? _decoded(text)
          : await Isolate.run(() => _decoded(text));
      if (draft == null || draft.path != path) {
        await quarantine(_support, file, 'unreadable viewer draft');
        return null;
      }
      return draft;
    } on Object catch (error) {
      log.w('read the viewer draft for $path', error);
      await quarantine(_support, file, error);
      return null;
    }
  }

  @override
  Future<void> drop(String path) async {
    final file = _fileFor(path);
    await withDirectoryLock(_folder, () async {
      if (await file.exists()) await file.delete();
    });
  }

  @override
  Future<void> setAside(String path) async {
    final file = _fileFor(path);
    await withDirectoryLock(_folder, () async {
      if (await file.exists()) {
        await quarantine(_support, file, 'newer unsaved edits replaced it');
      }
    });
  }

  static ViewerDraft? _decoded(String text) {
    final data = jsonDecode(text);
    if (data is! Map<String, Object?> ||
        data['version'] != version ||
        data['path'] is! String ||
        data['game'] is! int ||
        data['revision'] is! String ||
        data['text'] is! String) {
      return null;
    }
    return ViewerDraft(
      path: data['path'] as String,
      game: data['game'] as int,
      revision: Revision(data['revision'] as String),
      text: data['text'] as String,
    );
  }

  static const _offThreadFrom = 64 * 1024;
}
