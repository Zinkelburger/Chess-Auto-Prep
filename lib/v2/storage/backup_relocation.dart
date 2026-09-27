import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'backups.dart';
import 'relocation_notes.dart' show RecoveryRequired;

/// Which kept-version folder follows a document when it moves, recorded in
/// the move's journal so a restarted move carries the history the same way.
///
/// Kept versions follow a document, but they never decide whether it may
/// move: a history that cannot be moved stays under its old id, whole and
/// readable, and the move still completes.
final class BackupMove {
  BackupMove({
    required this.operationId,
    required this.rootPath,
    required this.fromId,
    required this.toId,
    required this.documentPath,
  }) {
    if (_id.stringMatch(fromId) != fromId ||
        _id.stringMatch(toId) != toId ||
        fromId == toId ||
        _operation.stringMatch(operationId) != operationId ||
        !_absolute(rootPath) ||
        !_absolute(documentPath)) {
      throw const RecoveryRequired('Invalid backup ownership plan.');
    }
  }

  /// Reads both this format and the earlier one, which also listed every kept
  /// file with its hash; that inventory is no longer needed and is ignored.
  factory BackupMove.fromJson(Map<String, Object?> json) {
    String text(String key) => switch (json[key]) {
      final String value => value,
      _ => throw const RecoveryRequired('Invalid backup ownership plan.'),
    };
    return BackupMove(
      operationId: text('operationId'),
      rootPath: text('rootPath'),
      fromId: text('fromId'),
      toId: text('toId'),
      documentPath: text('documentPath'),
    );
  }

  final String operationId;
  final String rootPath;
  final String fromId;
  final String toId;
  final String documentPath;

  Map<String, Object?> toJson() => {
    'version': 2,
    'operationId': operationId,
    'rootPath': rootPath,
    'fromId': fromId,
    'toId': toId,
    'documentPath': documentPath,
  };
}

/// Moves a document's kept versions to its new id. Every step checks what is
/// already on disk, so running it again after a stop finishes the move.
final class BackupRelocation {
  BackupRelocation(this.root, {required this.documents});

  final Directory root;

  /// The Documents folder, where a history displaced by a move is offered
  /// back as a deleted chapter.
  final Directory documents;

  /// Never throws: a failure is logged and leaves the history where it is.
  Future<void> applyMove(BackupMove move) async {
    try {
      final from = p.join(move.rootPath, move.fromId);
      final to = p.join(move.rootPath, move.toId);
      if (await _exists(from)) {
        if (await _exists(to)) await _displace(to, move);
        if (!await _exists(to)) await movePathNoReplace(from, to);
      }
      if (await _exists(to)) await _repointIndex(to, move.documentPath);
    } on Object catch (error) {
      log.w('move the kept versions of ${move.documentPath}', error);
    }
  }

  /// A history already under the target id belongs to a document that used to
  /// have that path and was renamed or removed by another program. Braiding
  /// the two would offer one document's text as a version of the other, so it
  /// moves out whole: its newest version goes to the deleted chapters of the
  /// folder the document lived in, and its history goes with it, so it can be
  /// restored from there like any deleted chapter.
  Future<void> _displace(String occupant, BackupMove move) async {
    final newest = await BackupArchive(root).newest(p.basename(occupant));
    final folder = p.dirname(move.documentPath);
    if (newest == null) {
      final aside = '$occupant.superseded-${move.operationId}';
      await movePathNoReplace(occupant, aside);
      log.w('set aside unreadable kept versions at $aside');
      return;
    }
    final stamp = newest.version.time.microsecondsSinceEpoch;
    final token = newest.version.hash.substring(0, 8);
    final name = '$stamp-$token-${p.basename(move.documentPath)}';
    final chapter = p.join(folder, '.cap-pgn-history', name);
    await Directory(p.dirname(chapter)).create(recursive: true);
    if (!await File(chapter).exists()) {
      await createFileExclusively(chapter, newest.bytes);
    }
    final id = backupId(p.relative(chapter, from: documents.path));
    await movePathNoReplace(occupant, p.join(move.rootPath, id));
    await _repointIndex(p.join(move.rootPath, id), chapter);
    log.w('offered the kept versions displaced from $occupant as $chapter');
  }

  Future<void> _repointIndex(String folder, String documentPath) async {
    final index = File(p.join(folder, 'index.json'));
    if (!await index.exists()) return;
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(await index.readAsBytes()));
    } on FormatException {
      return; // The archive rebuilds an index it cannot read.
    }
    if (json is! Map<String, Object?> || json['path'] == documentPath) return;
    await replaceFile(
      index.path,
      utf8.encode(jsonEncode({...json, 'path': documentPath})),
    );
  }
}

Future<bool> _exists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) ==
    FileSystemEntityType.directory;

bool _absolute(String value) =>
    !value.contains('\u0000') &&
    p.isAbsolute(value) &&
    p.normalize(value) == value;
final _id = RegExp(r'^[0-9a-f]{16}$');
final _operation = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
