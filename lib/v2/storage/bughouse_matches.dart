import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../chess/bughouse/match.dart';
import '../diagnostics/log.dart';
import 'atomic_write.dart';

sealed class MatchCreate {
  const MatchCreate();
}

final class MatchCreated extends MatchCreate {
  const MatchCreated(this.match);

  final StoredMatch match;
}

final class MatchCreateFailed extends MatchCreate {
  const MatchCreateFailed(this.detail);

  final String detail;
}

/// A write that did not happen, and why; null when it did.
typedef MatchWriteProblem = String?;

/// The bughouse matches on disk: one folder per match under
/// `Documents/bughouse_matches/`, holding `match.json` (the config and every
/// game) and `games.bpgn` (the games as BPGN, which `tools/bughouse_db`
/// indexes like the FICS archive). The old app reads and writes the same
/// folders; a deleted match goes to `.trash` beside them, as there.
abstract interface class MatchStore {
  /// Every match that reads, newest first; one that does not is left out.
  Future<List<StoredMatch>> list();

  /// A new folder named after [config], and its first `match.json`.
  Future<MatchCreate> create(MatchConfig config, DateTime now);

  /// Writes both files over the last ones.
  Future<MatchWriteProblem> save(StoredMatch match);

  /// Moves the match's folder to `.trash`.
  Future<MatchWriteProblem> delete(String id);
}

final class MatchFolder implements MatchStore {
  MatchFolder(this.root);

  /// `Documents/bughouse_matches`.
  final String root;

  static const _metadata = 'match.json';
  static const _bpgn = 'games.bpgn';

  @override
  Future<List<StoredMatch>> list() async {
    final folder = Directory(root);
    if (!await folder.exists()) return const [];
    final found = <StoredMatch>[];
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! Directory || p.basename(entry.path).startsWith('.')) {
        continue;
      }
      if (await _read(entry.path) case final match?) found.add(match);
    }
    found.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return found;
  }

  Future<StoredMatch?> _read(String folder) async {
    final file = File(p.join(folder, _metadata));
    try {
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, Object?>) return null;
      final match = StoredMatch.fromJson(json);
      // The folder's name is the id, whatever a hand-edited file says.
      return StoredMatch(
        id: p.basename(folder),
        config: match.config,
        createdAt: match.createdAt,
        finishedAt: match.finishedAt,
        status: match.status,
        error: match.error,
        games: match.games,
      );
    } on Object catch (error) {
      // One damaged match hides itself, not the list.
      log.w('read ${file.path}', error);
      return null;
    }
  }

  @override
  Future<MatchCreate> create(MatchConfig config, DateTime now) async {
    try {
      await Directory(root).create(recursive: true);
      final id = await _freeName(config.name);
      await Directory(p.join(root, id)).create();
      final match = StoredMatch(
        id: id,
        config: config,
        createdAt: now,
        status: MatchStatus.pending,
      );
      await createFileExclusively(
        p.join(root, id, _metadata),
        utf8.encode(_encoded(match)),
      );
      return MatchCreated(match);
    } on FileSystemException catch (error) {
      log.e('create a bughouse match in $root', error);
      return MatchCreateFailed(error.message);
    }
  }

  @override
  Future<MatchWriteProblem> save(StoredMatch match) async {
    final folder = p.join(root, match.id);
    try {
      await replaceFile(
        p.join(folder, _metadata),
        utf8.encode(_encoded(match)),
      );
      await replaceFile(p.join(folder, _bpgn), utf8.encode(matchBpgn(match)));
      return null;
    } on FileSystemException catch (error) {
      log.e('save the bughouse match in $folder', error);
      return error.message;
    }
  }

  @override
  Future<MatchWriteProblem> delete(String id) async {
    final folder = Directory(p.join(root, id));
    final trash = Directory(p.join(root, '.trash'));
    try {
      await trash.create(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      await folder.rename(p.join(trash.path, '$id-$stamp'));
      return null;
    } on FileSystemException catch (error) {
      log.e('delete the bughouse match $id', error);
      return error.message;
    }
  }

  /// [name] as a folder name, with `-2`, `-3`… when it is taken.
  Future<String> _freeName(String name) async {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = slug.isEmpty ? 'match' : slug;
    var candidate = base;
    for (var n = 2; await Directory(p.join(root, candidate)).exists(); n++) {
      candidate = '$base-$n';
    }
    return candidate;
  }

  static String _encoded(StoredMatch match) =>
      const JsonEncoder.withIndent('  ').convert(match.toJson());
}
