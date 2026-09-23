/// The chapters the user deleted, which are still on disk: a delete moves a
/// chapter into the recovery folder beside it (`document_relocation.dart`)
/// under `<microseconds>-<token>-<file name>`, the name both apps give it.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'document_relocation.dart' show recoveryFolder;

/// One deleted chapter file, and where it came from.
final class DeletedChapter {
  const DeletedChapter({
    required this.path,
    required this.folder,
    required this.name,
    required this.deletedAt,
  });

  /// The file in the recovery folder, absolute.
  final String path;

  /// The repertoire folder the chapter was deleted from, absolute. The
  /// recovery folder is inside it, so it is still there even when every
  /// chapter of the repertoire was deleted.
  final String folder;

  /// The chapter's name when it was deleted: its file name without `.pgn`.
  final String name;

  /// When it was deleted, read off its recovery name.
  final DateTime deletedAt;

  /// The repertoire's name, which is its folder's.
  String get repertoire => p.basename(folder);

  /// Where restoring it as [as] puts it: back in its folder, under its old
  /// name unless the user chose another.
  String restoredAs([String? as]) => p.join(folder, '${as ?? name}.pgn');
}

sealed class DeletedListing {
  const DeletedListing();
}

/// Every deleted chapter found, the most recently deleted first.
final class DeletedChapters extends DeletedListing {
  const DeletedChapters(this.chapters);

  final List<DeletedChapter> chapters;
}

/// The repertoires folder could not be read.
final class DeletedUnreadable extends DeletedListing {
  const DeletedUnreadable(this.detail);

  /// The operating system's message, for the log; the UI writes the sentence.
  final String detail;
}

/// The chapters in the recovery folder of every repertoire under [root].
///
/// Only chapter files are listed: the recovery folder also holds the old
/// app's kept versions (`<digest>.bytes`) and whatever else a lock left
/// there. A repertoire whose recovery folder cannot be read is passed over
/// with a log line, as the repertoire listing passes over a folder.
Future<DeletedListing> listDeleted(Directory root) async {
  if (!await root.exists()) return const DeletedChapters([]);
  final found = <DeletedChapter>[];
  try {
    await for (final entry in root.list()) {
      if (entry is! Directory || p.basename(entry.path).startsWith('.')) {
        continue;
      }
      found.addAll(await _deletedIn(entry.path));
    }
  } on FileSystemException catch (error) {
    log.w('list the deleted chapters under ${root.path}', error);
    return DeletedUnreadable(error.osError?.message ?? error.message);
  }
  found.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
  return DeletedChapters(List.unmodifiable(found));
}

Future<List<DeletedChapter>> _deletedIn(String folder) async {
  final trash = Directory(p.join(folder, recoveryFolder));
  final found = <DeletedChapter>[];
  try {
    if (!await trash.exists()) return found;
    await for (final entry in trash.list()) {
      if (entry is! File) continue;
      final chapter = readRecoveryName(entry.path, folder: folder);
      if (chapter != null) found.add(chapter);
    }
  } on FileSystemException catch (error) {
    log.w('list the deleted chapters in $folder', error);
  }
  return found;
}

/// The deleted chapter a recovery file at [path] is, or null when its name
/// is not one a delete gives: `<microseconds>-<hex token>-<name>.pgn`, and
/// not a raw-game sidecar, which was never a chapter.
DeletedChapter? readRecoveryName(String path, {required String folder}) {
  final match = _recoveryName.firstMatch(p.basename(path));
  if (match == null) return null;
  final name = match.group(2)!;
  if (name.endsWith('_raw_games')) return null;
  return DeletedChapter(
    path: path,
    folder: folder,
    name: name,
    deletedAt: DateTime.fromMicrosecondsSinceEpoch(int.parse(match.group(1)!)),
  );
}

final _recoveryName = RegExp(r'^(\d{1,17})-[0-9a-f]+-(.+)\.pgn$');
