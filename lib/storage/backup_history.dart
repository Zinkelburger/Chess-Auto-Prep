import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'backups.dart';
import 'document_ref.dart';
import 'file_lock.dart';
import 'recovery_gate.dart';

/// User-facing history shares the same lock as saves and archive relocation.
final class BackupHistory {
  BackupHistory(this.recovery)
    : archive = BackupArchive(
        Directory(p.join(recovery.support.path, 'backups')),
      );
  final RecoveryGate recovery;
  final BackupArchive archive;

  String _id(DocumentRef ref) {
    final root = p.normalize(recovery.documents.absolute.path);
    if (!p.isWithin(root, ref.path) || p.normalize(ref.path) != ref.path) {
      throw const FileSystemException('This document has no managed history.');
    }
    return backupId(p.relative(ref.path, from: root));
  }

  Future<T> _read<T>(Future<T> Function() work) =>
      recovery.run(() => withDirectoryLock(recovery.training.documents, work));

  Future<List<BackupVersion>> versions(DocumentRef ref) =>
      _read(() => archive.versions(_id(ref)));
  Future<String> text(DocumentRef ref, BackupVersion version) => _read(
    () async => utf8.decode(await archive.readVersion(_id(ref), version)),
  );

  /// Explicit cleanup keeps at least 100 versions and everything from 90 days.
  /// Recent undo receipts therefore retain their preimages.
  Future<int> prune(DocumentRef ref) => _read(
    () => archive.prune(
      _id(ref),
      olderThan: DateTime.now().toUtc().subtract(const Duration(days: 90)),
    ),
  );
}
